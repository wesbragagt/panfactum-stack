#!/usr/bin/env python3
"""Resolve Talos and Kubernetes access over private routing or fixed SSM."""

import argparse
import base64
from datetime import datetime, timezone
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import uuid
from urllib.parse import urlsplit


class AccessError(Exception):
    pass


class ControllerNotFound(AccessError):
    pass


class NoTunnelHost(AccessError):
    pass


class WaitTimeout(AccessError):
    pass


class ParentGone(Exception):
    pass


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def interrupted(signum, _frame):
    raise Interrupted(signum)


def command(argv, *, cwd=None, timeout=90, env=None):
    # Capture both streams: terragrunt output and diagnostics can contain secrets.
    # A separate process group lets signals clean up subprocess descendants too.
    process = subprocess.Popen(argv, cwd=cwd, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True, env=env)
    try:
        stdout, _stderr = process.communicate(timeout=timeout)
    except BaseException:
        stop_group(process)
        raise
    if process.returncode:
        raise AccessError(f"{Path(argv[0]).name} command failed (exit {process.returncode}); "
                          "diagnostics withheld to avoid exposing credentials")
    return stdout


def stop_group(process):
    # NOTE: The Session Manager plugin can remain alive after the AWS CLI exits.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def die_with_parent():
    # NOTE: This signals the direct child even when the helper cannot run cleanup.
    if not sys.platform.startswith("linux"):
        return
    try:
        import ctypes
        ctypes.CDLL(None).prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG
    except (OSError, AttributeError, ImportError):
        pass


def rotate_after(items, current):
    # Start after the endpoint that just failed, so a dead controller is tried last.
    if current not in items:
        return list(items)
    position = items.index(current) + 1
    return items[position:] + items[:position]


class Access:
    def __init__(self, args):
        self.args = args
        self.sessions = []
        self.reason = f"cluster-access-{args.cluster}-{uuid.uuid4().hex}"
        self.targets = set()
        self.closed_sessions = set()

    def aws_args(self, *args):
        # Omitted flags leave profile and region to the AWS environment and config.
        options = [item for flag, value in (("--profile", self.args.profile),
                                            ("--region", self.args.region)) if value
                   for item in (flag, value)]
        return ["aws", *options, "--no-cli-pager", "--cli-connect-timeout", "10",
                "--cli-read-timeout", "20", *args]

    def aws(self, *args, timeout=90):
        return json.loads(command(self.aws_args(*args, "--output", "json"), timeout=timeout))

    def instances(self, filters):
        response = self.aws("ec2", "describe-instances", "--filters", *filters)
        return [instance for reservation in response["Reservations"]
                for instance in reservation["Instances"]]

    def controllers(self, states):
        exact = self.args.control_plane_name
        prefix = f"{self.args.cluster}-control-plane-"
        # Reject AWS filter wildcards in operator input so the lookup stays a prefix or exact match.
        if any(char in value for value in (exact or prefix,) for char in "*?\\"):
            raise AccessError("Control-plane Name must be exact, without AWS wildcards")
        # Controllers are named <cluster>-control-plane-<position>.
        filters = [f"Name=tag:Name,Values={exact or prefix + '*'}",
                   f"Name=instance-state-name,Values={','.join(states)}"]
        if vpc_id := getattr(self.args, "vpc_id", None):
            filters.append(f"Name=vpc-id,Values={vpc_id}")
        found = self.instances(filters)
        named = []
        for node in found:
            name = next((tag["Value"] for tag in node.get("Tags", []) if tag["Key"] == "Name"), "")
            suffix = name[len(prefix):] if name.startswith(prefix) else ""
            if exact and name == exact or not exact and suffix.isdigit():
                named.append((name, suffix, node))
        if exact and len(named) > 1:
            raise AccessError(f"Expected at most one control plane with exact Name {exact}; "
                              f"found {len(named)}")

        def order(item):
            name, suffix, node = item
            # Running before pending, then by position; the address breaks a tie between same-Name instances.
            return (node.get("State", {}).get("Name") != "running",
                    int(suffix) if suffix.isdigit() else 0, name, node["PrivateIpAddress"])
        return [node for _name, _suffix, node in sorted(named, key=order)]

    def close_forwards(self):
        for process, _log in self.sessions:
            stop_group(process)
        # Parse only IDs, never print plugin output (which may contain diagnostics).
        ids = set()
        for _process, log in self.sessions:
            log.seek(0)
            ids.update(match.decode("ascii") for match in
                       re.findall(rb"SessionId:\s*([A-Za-z0-9_-]+)", log.read()))
            log.close()
        self.sessions.clear()
        # The unique reason also finds sessions created just before interruption,
        # before the CLI managed to print the session ID. Never terminate by target
        # alone: other operators may have active sessions on the same NAT.
        for target in sorted(self.targets):
            try:
                response = self.aws("ssm", "describe-sessions", "--state", "Active",
                                    "--filters", json.dumps([{"key": "Target", "value": target}]))
                ids.update(item["SessionId"] for item in response.get("Sessions", [])
                           if item.get("Reason") == self.reason)
            except (AccessError, subprocess.TimeoutExpired, ValueError):
                print("Warning: could not inventory this helper's remote SSM sessions", file=sys.stderr)
        for session_id in sorted(ids - self.closed_sessions):
            try:
                self.aws("ssm", "terminate-session", "--session-id", session_id)
                self.closed_sessions.add(session_id)
            except (AccessError, subprocess.TimeoutExpired, ValueError):
                print(f"Warning: could not terminate owned SSM session {session_id}", file=sys.stderr)

    def start_session(self, target, directory, document, parameters):
        log = tempfile.TemporaryFile(dir=directory)
        try:
            process = subprocess.Popen(
                self.aws_args("ssm", "start-session", "--target", target,
                              "--reason", self.reason, "--document-name", document, "--parameters",
                              json.dumps(parameters)), stdout=log, stderr=log,
                stdin=subprocess.DEVNULL, preexec_fn=die_with_parent,
                start_new_session=True)
        except BaseException:
            log.close()
            raise
        self.sessions.append((process, log))


def private_write(path, content):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(content)


def terragrunt_output(args, directory, name, *, output_format="-raw"):
    # A private download dir avoids the shared .terragrunt-cache, whose stale
    # copies make terragrunt fail with duplicate definitions.
    download = directory / "terragrunt-download"
    env = dict(os.environ, TERRAGRUNT_DOWNLOAD=str(download), TG_DOWNLOAD_DIR=str(download))
    # NOTE: The hook receives resolved VPN, but nested Terragrunt selects it from auto.
    if env.get("PF_TALOS_TRANSPORT") == "vpn":
        env.pop("PF_TALOS_TRANSPORT")
    if getattr(args, "transport", None) == "bootstrap_public":
        env["PF_TALOS_TRANSPORT"] = "bootstrap_public"
    if args.profile:
        env["AWS_PROFILE"] = args.profile
    if args.region:
        env["AWS_REGION"] = args.region
    try:
        return command(["terragrunt", "output", output_format, name], cwd=args.module, env=env)
    finally:
        shutil.rmtree(download, ignore_errors=True)


def is_ip(host):
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return False
    return True


def is_private_ip(value):
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return False
    return isinstance(value, str) and any(address in ipaddress.ip_network(network)
                                         for network in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7"))


def is_dns_name(host):
    return isinstance(host, str) and "." in host and all(
        re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label) for label in host.split("."))


def validate_public_endpoint(host, node):
    if not is_dns_name(host) or is_ip(host) or not is_private_ip(node):
        raise AccessError("public bootstrap needs a load balancer hostname and private controller IP; "
                          "check the cluster registration")


def validate_private_endpoints(server, endpoints):
    try:
        url = urlsplit(server)
        host = url.hostname
        if (not isinstance(server, str) or url.scheme != "https" or url.port != 6443 or not host
                or not (is_private_ip(host) if is_ip(host) else is_dns_name(host))
                or url.username is not None or url.path not in ("", "/") or url.query or url.fragment
                or any(char.isspace() for char in server)):
            raise ValueError
    except (TypeError, ValueError) as exc:
        raise AccessError("kube_api_server must be a private HTTPS API endpoint on port 6443; "
                          "check the cluster registration") from exc
    if not isinstance(endpoints, list) or not endpoints or not all(map(is_private_ip, endpoints)):
        raise AccessError("talos_endpoints must list private controller IPs; check the cluster registration")


def client_endpoint(transport, host, port, local_port):
    if transport == "ssm":
        return f"127.0.0.1:{local_port}", "127.0.0.1"
    authority = f"[{host}]" if ":" in host else host
    return f"{authority}:{port}", host


def read_source_kubeconfig(args, directory):
    source = directory / "source-kubeconfig"
    if args.source_kubeconfig is not None:
        private_write(source, args.source_kubeconfig.read_bytes())
    else:
        private_write(source, terragrunt_output(args, directory, "kubeconfig"))
    # kubectl supplies the YAML parser; the Python implementation is stdlib only.
    try:
        return json.loads(command(["kubectl", "--kubeconfig", str(source), "config", "view",
                                   "--raw", "--flatten", "-o", "json"]))
    finally:
        source.unlink()


def kubeconfig(args, directory):
    config = read_source_kubeconfig(args, directory)
    context = next((item["context"] for item in config.get("contexts", [])
                    if item["name"] == config.get("current-context")), None)
    if context is None:
        raise AccessError("Terragrunt kubeconfig has no current context")
    cluster = next((item["cluster"] for item in config.get("clusters", [])
                    if item["name"] == context["cluster"]), None)
    if cluster is None or not cluster.get("certificate-authority-data"):
        raise AccessError("Terragrunt kubeconfig has no embedded cluster CA")
    cluster.pop("insecure-skip-tls-verify", None)
    address, identity = client_endpoint("ssm", None, 6443, args.kube_port)
    cluster["server"] = f"https://{address}"
    cluster["tls-server-name"] = identity
    # A source proxy would bypass the local forward.
    cluster.pop("proxy-url", None)
    tls_context = ssl.create_default_context(
        cadata=base64.b64decode(cluster["certificate-authority-data"], validate=True).decode("ascii"))
    path = directory / "kubeconfig.json"
    private_write(path, json.dumps(config).encode())
    return path, tls_context


def talosconfig(args, directory, private_ip, endpoints=None):
    path = directory / "talosconfig"
    source = args.source_talosconfig
    private_write(path, source.read_bytes() if source else terragrunt_output(args, directory, "talosconfig"))
    # talosctl rewrites its own YAML; the CA is a single base64 scalar in the context.
    command(["talosctl", "--talosconfig", str(path), "config", "endpoint",
             *(endpoints or [client_endpoint("ssm", None, 50000, args.talos_port)[0]])])
    command(["talosctl", "--talosconfig", str(path), "config", "node", private_ip])
    match = re.search(r"^\s+ca:\s*(\S+)\s*$", path.read_text(), re.MULTILINE)
    if match is None:
        raise AccessError("Terragrunt talosconfig has no embedded CA")
    ssl.create_default_context(
        cadata=base64.b64decode(match.group(1), validate=True).decode("ascii"))
    path.chmod(0o600)
    return path


def require_free_port(port):
    # Refuse existing listeners, rather than mistaking someone else's tunnel
    # for our own or killing a process we did not create.
    with socket.socket() as probe:
        try:
            # NOTE: A prior forward's TCP connections can still be in TIME_WAIT on reconnect.
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            probe.bind(("127.0.0.1", port))
        except OSError as exc:
            raise AccessError(f"Local port {port} is already in use") from exc


def alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def nap(args, seconds):
    # Sleep in slices so a background helper notices its parent exiting within ~0.5 s.
    end = time.monotonic() + seconds
    while True:
        if args.parent is not None and not alive(args.parent):
            raise ParentGone()
        remaining = end - time.monotonic()
        if remaining <= 0:
            return
        time.sleep(min(0.5, remaining))


def wait_for_controller(args, access):
    deadline = time.monotonic() + args.wait
    while True:
        try:
            # A pending instance already has its private IP, and Talos is reachable once it listens.
            private_ips, candidates = access.discover(("pending", "running"))
            return private_ips[0], candidates
        except (ControllerNotFound, NoTunnelHost) as exc:
            # A jump host created with the controller needs minutes to register with SSM.
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise WaitTimeout(f"Timed out after {args.wait:g}s waiting for the control plane "
                                  f"and an SSM Online tunnel host: {exc}")
            nap(args, min(5, remaining))


def bootstrap(args, access):
    require_free_port(args.talos_port)
    private_ip, candidates = wait_for_controller(args, access)
    with tempfile.TemporaryDirectory(prefix="cluster-access-") as directory:
        target = access.establish_bootstrap(candidates, Path(directory), args.talos_port, 50000)
        print(f"Controller private IP: {private_ip}")
        print(f"SSM target: {target}")
        print(f'talos_api_endpoint = "127.0.0.1:{args.talos_port}"')
        print("Forwarding Talos only; keep this process running. Ctrl-C stops the owned session.", flush=True)
        try:
            while True:
                if any(process.poll() is not None for process, _ in access.sessions):
                    raise AccessError("The SSM forward exited")
                time.sleep(0.5)
        finally:
            for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                signal.signal(signum, signal.SIG_IGN)
            # Log files must outlive session-ID parsing in close_forwards.
            access.close_forwards()


def background_run(args, access, initial, ready):
    forwards = [(access, args.talos_port, 50000)]
    if args.terragrunt_hook:
        # NOTE: A Kubernetes DNS/port failure during cold boot must not close the Talos session.
        kube_access = access.separate_sessions()
        forwards.append((kube_access, args.kube_port, 6443))
    retry_at = {}
    retry_until = {}
    started_at = {}
    with tempfile.TemporaryDirectory(prefix="cluster-access-") as directory:
        try:
            # A first apply must be able to create the controller and the SSM host.
            if initial is None:
                ready()
            while True:
                discovery = initial
                for tunnel, local_port, remote_port in forwards:
                    now = time.monotonic()
                    if tunnel.sessions:
                        if tunnel.sessions[0][0].poll() is None:
                            continue
                        print(f"SSM forward for API port {remote_port} exited", file=sys.stderr)
                        tunnel.close_forwards()
                        if now - started_at[remote_port] > 60:
                            retry_until.pop(remote_port, None)
                        if now >= retry_until.setdefault(remote_port, now + args.wait):
                            raise AccessError(f"SSM forward for API port {remote_port} did not stabilize")
                    if now < retry_at.get(remote_port, 0):
                        continue
                    try:
                        if discovery is None:
                            discovery = wait_for_controller(args, access)
                        _, candidates = discovery
                        tunnel.establish_bootstrap(candidates, Path(directory), local_port, remote_port)
                        started_at[remote_port] = time.monotonic()
                    except WaitTimeout as exc:
                        # A plan of a cluster that does not exist yet needs no tunnel.
                        print(f"cluster-access: {exc}", file=sys.stderr)
                        return 0
                    except AccessError as exc:
                        now = time.monotonic()
                        if initial is not None or now >= retry_until.setdefault(remote_port, now + args.wait):
                            raise
                        print(f"SSM forward for API port {remote_port}: {exc}", file=sys.stderr)
                        retry_at[remote_port] = now + 2
                if initial is not None:
                    ready()
                    initial = None
                nap(args, 0.5)
        finally:
            for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                signal.signal(signum, signal.SIG_IGN)
            for tunnel, _, _ in forwards:
                tunnel.close_forwards()


def read_state(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def run_detached(args, access, parent, directory, write_fd, initial):
    record = directory / "bootstrap.json"
    code = 1
    try:
        devnull = os.open(os.devnull, os.O_RDONLY)
        log = os.open(directory / "bootstrap.log", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.dup2(devnull, 0)
        os.dup2(log, 1)
        os.dup2(log, 2)
        os.close(devnull)
        os.close(log)
        sys.stdout.reconfigure(line_buffering=True)
        sys.stderr.reconfigure(line_buffering=True)
        pending = record.with_suffix(".tmp")
        pending.unlink(missing_ok=True)
        private_write(pending, json.dumps(
            {"pid": os.getpid(), "parent": parent, "talos_port": args.talos_port,
             **({"kube_port": args.kube_port} if args.terragrunt_hook else {})}).encode())
        pending.replace(record)
        def ready():
            os.write(write_fd, str(os.getpid()).encode())
            os.close(write_fd)

        args.parent = parent
        code = background_run(args, access, initial, ready)
    except (ParentGone, Interrupted) as exc:
        code = 0 if isinstance(exc, ParentGone) else 128 + exc.signum
    except (AccessError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as exc:
        print(f"cluster-access: {exc if isinstance(exc, AccessError) else type(exc).__name__}",
              file=sys.stderr, flush=True)
    finally:
        state = read_state(record)
        if isinstance(state, dict) and state.get("pid") == os.getpid():
            record.unlink(missing_ok=True)
        os._exit(code)


def background(args, access):
    """Start bootstrap forwards detached from Terragrunt."""
    directory = args.state_dir
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    parent = os.getppid()
    port = args.talos_port
    # The lock only serializes concurrent hooks around the decision and the record write.
    with (directory / "bootstrap.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        previous = read_state(directory / "bootstrap.json")
        if (isinstance(previous, dict) and previous.get("talos_port") == port
                and alive(previous.get("pid"))):
            if alive(previous.get("parent")):
                if args.terragrunt_hook:
                    raise AccessError(f"Local Talos port {port} is reserved by another tunnel helper")
                print(f"reusing background helper {previous['pid']} for {args.cluster} on 127.0.0.1:{port}")
                return 0
            # Its parent is gone, so it is closing its forward; wait for the port to free up.
            deadline = time.monotonic() + 10
            while alive(previous["pid"]) and time.monotonic() < deadline:
                time.sleep(0.2)
        require_free_port(port)
        initial = None
        if args.terragrunt_hook:
            require_free_port(args.kube_port)
            # An existing cluster may need its API during the first provider refresh.
            try:
                private_ips, candidates = access.discover(("pending", "running"))
            except (ControllerNotFound, NoTunnelHost) as exc:
                print(f"Waiting in the background for Talos tunnel discovery: {exc}")
            else:
                initial = private_ips[0], candidates
        read_fd, write_fd = os.pipe()
        child = os.fork()
        if child == 0:
            try:
                os.close(read_fd)
                lock.close()
                os.setsid()
                if os.fork() == 0:
                    run_detached(args, access, parent, directory, write_fd, initial)
            finally:
                os._exit(0)
        os.close(write_fd)
        helper = os.read(read_fd, 32)
        os.close(read_fd)
        os.waitpid(child, 0)
    if not helper:
        raise AccessError(f"Background Talos helper failed to start; see {directory / 'bootstrap.log'}")
    print(f"Talos tunnel helper {helper.decode()} log: {directory / 'bootstrap.log'}")
    print(f'talos_api_endpoint = "127.0.0.1:{port}"', flush=True)
    return 0


def tls_verifies(port, tls_context):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
            with tls_context.wrap_socket(connection, server_hostname="127.0.0.1"):
                return True
    except (OSError, ssl.SSLError):
        return False


def ensure_access(args, forwarded):
    directory = args.state_dir
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    state = directory / "ready.json"
    key = "talosconfig" if args.talos_config else "kubeconfig"
    with (directory / "startup.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if state.exists():
            ready = json.loads(state.read_text())
            try:
                os.kill(ready["pid"], 0)
            except ProcessLookupError:
                state.unlink()
            else:
                if not Path(ready[key]).is_file():
                    raise AccessError("Existing tunnel is closing; reload direnv after it exits")
                # NOTE: The daemon owns route checks and reconnects behind this address.
                args.report(ready[key])
                return 0
        log_path = directory / "access.log"
        descriptor = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as log:
            process = subprocess.Popen(
                [sys.executable, str(Path(__file__).resolve()), *forwarded, "--ready-file", str(state)],
                stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
        deadline = time.monotonic() + 120
        try:
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise AccessError(f"Tunnel startup failed; see {log_path}")
                if state.exists():
                    args.report(json.loads(state.read_text())[key])
                    return 0
                time.sleep(0.2)
            raise AccessError(f"Tunnel startup timed out; see {log_path}")
        except BaseException:
            stop_group(process)
            raise


LOOPBACK_HEX = ("0100007F", "0000000000000000FFFF00000100007F")  # 127.0.0.1 in tcp and tcp6


def established_connections(port):
    # Counts ESTABLISHED sockets on 127.0.0.1:<port>. None means unknown, which callers treat as busy.
    try:
        if sys.platform.startswith("linux"):
            count = 0
            for table in ("/proc/net/tcp", "/proc/net/tcp6"):
                with open(table) as rows:
                    for row in rows.readlines()[1:]:
                        fields = row.split()
                        address, _, hex_port = fields[1].partition(":")
                        if fields[3] == "01" and address in LOOPBACK_HEX and int(hex_port, 16) == port:
                            count += 1
            return count
        # lsof also matches the client end of each connection, which only errs toward busy.
        result = subprocess.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:ESTABLISHED"],
                                capture_output=True, text=True, timeout=10)
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
        return None
    if result.returncode not in (0, 1):
        return None
    # lsof exits 1 when nothing matches; otherwise its first line is a header.
    return max(len(result.stdout.splitlines()) - 1, 0)


def last_activity(args, last_active):
    # Each successful --ensure or --exec-credential touches the lease; an open connection is activity now.
    try:
        last_active = max(last_active, (args.state_dir / "lease").stat().st_mtime)
    except OSError:
        pass
    if any(established_connections(port) != 0 for port in (args.kube_port, args.talos_port)):
        return time.time()
    return last_active


def close_when_idle(args, access, last_active):
    """Close an idle tunnel as SIGTERM does; return the last activity time, or None after closing."""
    with (args.state_dir / "startup.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            # An --ensure holds the lock and touches the lease when it succeeds.
            return last_active
        last_active = last_activity(args, last_active)
        idle = time.time() - last_active
        if idle < args.idle_timeout:
            return last_active
        print(f"idle for {int(idle)}s; closing tunnel", flush=True)
        access.close_forwards()
        (args.state_dir / "ready.json").unlink(missing_ok=True)
        (args.state_dir / "credential.json").unlink(missing_ok=True)
        return None


def replace_json(path, value):
    # Unique temp name so concurrent writers never share or corrupt a file.
    pending = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    pending.unlink(missing_ok=True)
    private_write(pending, json.dumps(value).encode())
    pending.replace(path)


def mark_ok(state):
    ready = read_state(state)
    # A tunnel that exited removed ready.json; do not resurrect it.
    if isinstance(ready, dict) and state.exists():
        ready["last_ok"] = time.time()
        replace_json(state, ready)


def credential_status(config, directory):
    try:
        context = next(item["context"] for item in config["contexts"] if item["name"] == config["current-context"])
        user = next(item["user"] for item in config["users"] if item["name"] == context["user"])
        status = {key: base64.b64decode(user[field], validate=True).decode("ascii")
                  for key, field in (("clientCertificateData", "client-certificate-data"),
                                     ("clientKeyData", "client-key-data"))}
        if not all(status.values()):
            raise ValueError
    except (KeyError, StopIteration, TypeError, ValueError) as exc:
        raise AccessError("The protected kubeconfig has no usable client certificate and key") from exc
    path = directory / "client-certificate.pem"
    private_write(path, status["clientCertificateData"].encode())
    output = command(["openssl", "x509", "-noout", "-enddate", "-in", str(path)]).decode().strip()
    expiry = ssl.cert_time_to_seconds(output.removeprefix("notAfter="))
    if expiry <= time.time():
        raise AccessError("The protected kubeconfig client certificate has expired; refresh it at the source")
    status["expirationTimestamp"] = datetime.fromtimestamp(expiry, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return status


def unexpired_status(cache):
    try:
        status = {field: cache[field] for field in ("clientCertificateData", "clientKeyData", "expirationTimestamp")}
        if all(isinstance(value, str) and value for value in status.values()) and time.time() < (
            datetime.strptime(status["expirationTimestamp"], "%Y-%m-%dT%H:%M:%SZ")
            .replace(tzinfo=timezone.utc).timestamp()
        ):
            return status
    except (KeyError, OverflowError, TypeError, ValueError):
        return None
    return None


def cached_credential(args, ready, credential):
    """Return the cached ExecCredential status when the tunnel is alive and its TLS verifies, else None."""
    try:
        os.kill(ready["pid"], 0)
        cache = json.loads(credential.read_text())
        if cache["kubeconfig"] != ready["kubeconfig"]:
            return None
        config = json.loads(Path(ready["kubeconfig"]).read_text())
        context = next(item["context"] for item in config["contexts"]
                       if item["name"] == config["current-context"])
        cluster = next(item["cluster"] for item in config["clusters"] if item["name"] == context["cluster"])
        tls_context = ssl.create_default_context(
            cadata=base64.b64decode(cluster["certificate-authority-data"], validate=True).decode("ascii"))
        status = unexpired_status(cache)
    except (OSError, ValueError, KeyError, StopIteration, TypeError, ssl.SSLError):
        return None
    return status if status and tls_verifies(args.kube_port, tls_context) else None


def warm_credential(args):
    state = args.state_dir / "ready.json"
    ready = read_state(state)
    if not isinstance(ready, dict):
        return None
    status = cached_credential(args, ready, args.state_dir / "credential.json")
    if status is None:
        return None
    last_ok = ready.get("last_ok")
    if not isinstance(last_ok, (int, float)) or time.time() - last_ok >= 30:
        try:
            command(["kubectl", "--kubeconfig", ready["kubeconfig"],
                     "--request-timeout=15s", "get", "--raw=/readyz"], timeout=20)
        except (AccessError, subprocess.TimeoutExpired):
            return None
        mark_ok(state)
    return status


def vpn_directory(args):
    directory = args.state_dir / "vpn"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    return directory


def vpn_cache_key(args, *components):
    identity = (str(args.module.resolve()), str(args.source_kubeconfig),
                args.profile or os.environ.get("AWS_PROFILE"), args.region or os.environ.get("AWS_REGION"), *components)
    return hashlib.sha256(json.dumps(identity).encode()).hexdigest()


def vpn_credential(args):
    directory = vpn_directory(args)
    identity = vpn_cache_key(args)
    path = directory / f"credential-{identity}.json"
    with (directory / f"credential-{identity}.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        status = unexpired_status(read_state(path))
        if status is None:
            with tempfile.TemporaryDirectory(dir=directory) as temporary:
                scratch = Path(temporary)
                status = credential_status(read_source_kubeconfig(args, scratch), scratch)
            replace_json(path, status)
    return status


def direct_talosconfig(args):
    directory = vpn_directory(args)
    if args.transport == "bootstrap_public":
        node = args.node
        endpoints = [client_endpoint(args.transport, args.bootstrap_public_host, 50000, None)[0]]
    else:
        node = args.node or args.talos_endpoint[0]
        endpoints = [node] if args.node in args.talos_endpoint else args.talos_endpoint
    path = directory / f"talosconfig-{vpn_cache_key(args, node, endpoints, str(args.source_talosconfig))}"
    with tempfile.TemporaryDirectory(dir=directory) as temporary:
        config = talosconfig(args, Path(temporary), node, endpoints)
        config.replace(path)
    print(path)


def ssm_credential(args, forwarded):
    status = warm_credential(args)
    if status is None:
        paths = []
        args.report = paths.append
        ensure_access(args, forwarded)
        config = json.loads(Path(paths[0]).read_text())
        with tempfile.TemporaryDirectory(dir=args.state_dir) as temporary:
            status = credential_status(config, Path(temporary))
        replace_json(args.state_dir / "credential.json", {**status, "kubeconfig": paths[0]})
        mark_ok(args.state_dir / "ready.json")
    return status


def exec_credential(args, forwarded):
    status = ssm_credential(args, forwarded) if args.transport == "ssm" else vpn_credential(args)
    print(json.dumps({"apiVersion": "client.authentication.k8s.io/v1", "kind": "ExecCredential",
                      "status": status}))
    return 0


def configure_fixed_ssm(args):
    # NOTE: The fixed helper imports these shared types when this file is run as a script.
    if __name__ == "__main__":
        sys.modules["cluster_access"] = sys.modules[__name__]
    import operator_tunnel

    path = args.fixed_ssm.resolve()
    try:
        config = json.loads(path.read_text())
        account = config["account_id"]
        vpc = config["vpc_id"]
        hosts = config["instance_ids"]
        nat_hosts = config.get("nat_host_ids", [])
        node = args.node or config.get("controller_ip")
        if (config["cluster"] != args.cluster or not re.fullmatch(r"[0-9]{12}", account)
                or not re.fullmatch(r"vpc-[0-9a-f]+", vpc)
                or getattr(args, "account_id", account) != account
                or getattr(args, "vpc_id", None) not in (None, vpc)
                or not isinstance(hosts, list) or not 1 <= len(hosts) <= 50
                or not all(map(operator_tunnel.instance_id, hosts)) or len(set(hosts)) != len(hosts)
                or not isinstance(nat_hosts, list) or not all(map(operator_tunnel.instance_id, nat_hosts))
                or set(nat_hosts).intersection(hosts)
                or ((args.bootstrap or args.talos_config) and not is_private_ip(node))
                or not isinstance(config["document_destinations"], dict)):
            raise ValueError
        kube_host = config.get("kube_host")
        args.kube_host = operator_tunnel.hostname(kube_host) if kube_host else None
    except (OSError, ValueError, TypeError, KeyError, AttributeError) as exc:
        raise AccessError(f"Fix the cluster, AWS scope, host IDs or document map in {path} for {args.cluster}") from exc
    if args.nat_host and args.nat_host not in nat_hosts:
        raise AccessError(f"Select a privileged NAT from nat_host_ids in {path}")
    args.account_id, args.vpc_id = account, vpc
    args.approved_jump_host = hosts
    args.controller_ip = node
    args.document_entries = config["document_destinations"]
    args.mode = "bootstrap" if args.bootstrap else "talos" if args.talos_config else "operator"
    args.talosconfig = None
    args.kube_tls_name = client_endpoint("ssm", None, 6443, args.kube_port)[1]
    args.reconnect_timeout = 120
    args.fixed_ssm = path
    identity = (config, args.mode, args.nat_host, node if args.mode != "operator" else None, str(args.module.resolve()),
                str(args.source_kubeconfig), str(args.source_talosconfig), args.profile or os.environ.get("AWS_PROFILE"),
                args.region or os.environ.get("AWS_REGION"), args.kube_port, args.talos_port)
    digest = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    args.state_dir = args.state_dir / "fixed-ssm" / digest
    if args.ready_file is not None and args.ready_file.parent != args.state_dir:
        raise AccessError("Fixed SSM configuration changed while starting the tunnel")
    return operator_tunnel


def fixed_access(args, fixed):
    access = fixed.OperatorAccess(args)
    access.prepare()
    if args.preflight:
        print(f"SSM Online: {', '.join(access.discover_hosts())}")
        return 0
    if args.bootstrap:
        if args.background:
            return background(args, access)
        bootstrap(args, access)
        return 0

    args.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix="forward-", dir=args.state_dir) as temporary:
            directory = Path(temporary)
            if args.talos_config:
                args.talosconfig = talosconfig(args, directory, args.controller_ip)
                key, config, ports = "talosconfig", args.talosconfig, [(args.talos_port, 50000)]
            else:
                config, access.kube_tls = kubeconfig(args, directory)
                key, ports = "kubeconfig", [(args.kube_port, 6443)]

            def ready():
                if args.ready_file is None:
                    print(config, flush=True)
                else:
                    replace_json(args.ready_file, {"pid": os.getpid(), key: str(config)})

            last_active = time.time()
            next_idle_check = 0

            def active():
                nonlocal last_active, next_idle_check
                if args.ready_file is not None and args.idle_timeout and time.monotonic() >= next_idle_check:
                    next_idle_check = time.monotonic() + args.idle_check_interval
                    last_active = close_when_idle(args, access, last_active)
                return last_active is not None

            fixed.run_forwards(args, access, directory, ports, ready, active)
    finally:
        if args.ready_file is not None:
            record = read_state(args.ready_file)
            if isinstance(record, dict) and record.get("pid") == os.getpid():
                args.ready_file.unlink(missing_ok=True)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cluster",
                        help="Terraform cluster Name prefix (default: TF_VAR_cluster_name)")
    parser.add_argument("--profile", help="AWS profile (default: AWS environment)")
    parser.add_argument("--region", help="AWS region (default: AWS environment)")
    parser.add_argument("--kube-port", type=int, default=os.environ.get("PF_TALOS_KUBE_PORT", "16443"),
                        help="local Kubernetes API port (default: PF_TALOS_KUBE_PORT or 16443)")
    parser.add_argument("--talos-port", type=int, default=50000, help="local Talos API port (default: 50000)")
    parser.add_argument("--module", type=Path, default=Path.cwd(),
                        help="terragrunt caller directory for the outputs (default: current directory)")
    parser.add_argument("--source-kubeconfig", type=Path,
                        help="local kubeconfig to use instead of the terragrunt output")
    parser.add_argument("--source-talosconfig", type=Path,
                        help="local Talos credentials to use instead of the terragrunt output")
    parser.add_argument("--state-dir", type=Path,
                        help="--ensure state (default: ${XDG_STATE_HOME:-~/.local/state}/talos-cluster-access/CLUSTER)")
    parser.add_argument("--ready-timeout", type=float, default=30,
                        help="startup deadline in seconds per tunnel host (default: 30)")
    parser.add_argument("--ensure", action="store_true",
                        help="start or reuse background access and print its kubeconfig")
    parser.add_argument("--exec-credential", action="store_true",
                        help="kubectl exec plugin: print an ExecCredential for the selected transport")
    parser.add_argument("--transport", choices=("vpn", "ssm", "bootstrap_public"), default="ssm",
                        help="direct VPN or public bootstrap access, or SSM tunnel (default: ssm)")
    parser.add_argument("--fixed-ssm", type=Path, help="fixed document and host JSON (default: PF_TALOS_FIXED_SSM)")
    parser.add_argument("--nat-host", help="pin a configured NAT for privileged --talos-config recovery")
    parser.add_argument("--preflight", action="store_true", help="verify fixed documents and Online hosts without sessions")
    parser.add_argument("--talos-config", action="store_true", help="print the path of a protected talosconfig")
    parser.add_argument("--talos-endpoint", action="append", help="private controller IP; repeatable with --talos-config")
    parser.add_argument("--bootstrap-public-host", help="public load balancer hostname for --talos-config")
    parser.add_argument("--node", help="private Talos node IP for --talos-config")
    parser.add_argument("--bootstrap", action="store_true",
                        help="wait for a pending or running controller and forward only its Talos port")
    parser.add_argument("--wait", type=float, default=900,
                        help="--bootstrap: seconds to wait for the controller (default: 900)")
    parser.add_argument("--background", action="store_true",
                        help="--bootstrap: detach and return at once; the helper exits with its parent process "
                             "(for a terragrunt before_hook)")
    parser.add_argument("--terragrunt-hook", action="store_true",
                        help="use the Panfactum AWS provider configuration and verify its account")
    parser.add_argument("--idle-timeout", type=int, default=3600,
                        help="--ensure daemon: exit after this many seconds with no successful --ensure or "
                             "--exec-credential and no open connection; 0 disables (default: 3600)")
    # Tests only: a short check interval, which also allows idle timeouts below 60 s.
    parser.add_argument("--idle-check-interval", type=float, help=argparse.SUPPRESS)
    parser.add_argument("--ready-file", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()  # --help exits before credentials, AWS or tool discovery.
    if args.cluster is None:
        # Terragrunt v0.69.1 exports string inputs without JSON quotes.
        args.cluster = os.environ.get("TF_VAR_cluster_name")
    if not args.cluster or not args.cluster.strip():
        parser.error("Set --cluster or declare inputs.cluster_name (TF_VAR_cluster_name)")
    if args.cluster in (".", "..") or any(char in args.cluster for char in "/\\*?,"):
        parser.error("Cluster name must be a single name without path separators, AWS wildcards or commas")
    if args.terragrunt_hook:
        transport = os.environ.get("TF_VAR_talos_access_transport") or os.environ.get("PF_TALOS_TRANSPORT")
        if transport in ("vpn", "bootstrap_public"):
            return 0
    if args.transport == "ssm" and args.fixed_ssm is None:
        if path := os.environ.get("PF_TALOS_FIXED_SSM"):
            args.fixed_ssm = Path(path)
        else:
            parser.error("Set PF_TALOS_FIXED_SSM or pass --fixed-ssm FILE to use SSM")
    if args.fixed_ssm and args.transport != "ssm":
        parser.error("--fixed-ssm requires --transport ssm")
    if args.nat_host and (args.transport != "ssm" or not args.talos_config):
        parser.error("--nat-host requires privileged SSM --talos-config")
    if args.preflight and (args.transport != "ssm" or args.ensure or args.exec_credential
                           or args.talos_config or args.background):
        parser.error("--preflight checks SSM documents and hosts without starting access")
    if args.transport != "ssm" and not ((args.exec_credential or args.talos_config)
                                         and not (args.bootstrap or args.ensure or args.background)):
        parser.error("direct access uses --exec-credential or --talos-config; use --transport ssm --ensure for recovery")
    if args.bootstrap_public_host and not (args.transport == "bootstrap_public" and args.talos_config):
        parser.error("--bootstrap-public-host requires --transport bootstrap_public --talos-config")
    if args.talos_config:
        if args.exec_credential or args.bootstrap or args.ensure:
            parser.error("--talos-config excludes --exec-credential, --bootstrap and --ensure")
        if args.transport == "vpn" and (not args.talos_endpoint or not all(map(is_private_ip, args.talos_endpoint))):
            parser.error("--talos-config requires private controller IPs in --talos-endpoint")
        if args.transport == "bootstrap_public":
            try:
                validate_public_endpoint(args.bootstrap_public_host, args.node)
            except AccessError as exc:
                parser.error(str(exc))
        if args.fixed_ssm and args.talos_endpoint:
            parser.error("Fixed SSM selects the Talos document by --node")
        if args.node is not None and not is_private_ip(args.node):
            parser.error("--node must be a private IP")
    elif args.talos_endpoint or args.node or args.source_talosconfig:
        parser.error("--talos-endpoint, --node and --source-talosconfig require --talos-config")
    if args.terragrunt_hook:
        if not (args.bootstrap and args.background):
            parser.error("--terragrunt-hook requires --bootstrap --background")
        # The VPC dependency identifies the right controllers if a name is reused elsewhere.
        args.vpc_id = os.environ.get("TF_VAR_vpc_id")
        if args.vpc_id and not re.fullmatch(r"vpc-[0-9a-f]+", args.vpc_id):
            parser.error("inputs.vpc_id (TF_VAR_vpc_id) must be an AWS VPC ID")
        for name in ("profile", "region", "account_id"):
            env_name = f"PF_TALOS_AWS_{name.upper()}"
            value = os.environ.get(env_name, "").strip()
            if not value:
                parser.error(f"{env_name} is required from the Panfactum AWS provider configuration")
            setattr(args, name, value)
    args.control_plane_name = None
    args.report = print
    args.parent = None
    if args.background and not args.bootstrap:
        print("cluster-access: --background requires --bootstrap", file=sys.stderr)
        return 1
    if args.exec_credential and args.ensure:
        print("cluster-access: --exec-credential excludes --ensure", file=sys.stderr)
        return 1
    if args.bootstrap and (args.ensure or args.exec_credential):
        print("cluster-access: --bootstrap excludes --ensure and --exec-credential", file=sys.stderr)
        return 1
    if not (args.wait > 0 and all(1 <= port <= 65535 for port in (args.kube_port, args.talos_port))):
        print("cluster-access: --wait must be positive and ports within 1-65535", file=sys.stderr)
        return 1
    if not 0 < args.ready_timeout <= 300:
        parser.error("--ready-timeout must be greater than zero and at most 300 seconds")
    if args.idle_timeout < 0 or (args.idle_timeout and args.idle_check_interval is None
                                 and not 60 <= args.idle_timeout <= 86400):
        parser.error("--idle-timeout must be 0 or between 60 and 86400 seconds")
    if args.idle_check_interval is None:
        args.idle_check_interval = 30
    if args.preflight:
        binaries = ("aws", "session-manager-plugin")
    elif args.talos_config:
        binaries = ("talosctl",) + (("terragrunt",) if args.source_talosconfig is None else ())
        if args.fixed_ssm:
            binaries += ("aws", "session-manager-plugin")
    elif args.transport != "ssm":
        binaries = ("kubectl", "openssl") + (("terragrunt",) if args.source_kubeconfig is None else ())
    else:
        binaries = ("aws", "session-manager-plugin") + (() if args.bootstrap else ("kubectl",))
        if args.source_kubeconfig is None and not args.bootstrap:
            binaries += ("terragrunt",)
        if args.exec_credential:
            binaries += ("openssl",)
    for binary in binaries:
        if not shutil.which(binary):
            if args.exec_credential:
                print(f"cluster-access: required executable missing: {binary}", file=sys.stderr)
                return 1
            parser.error(f"Required executable missing: {binary}")
    os.umask(0o077)
    if args.state_dir is None:
        state_home = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
        args.state_dir = state_home / "talos-cluster-access" / args.cluster
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    fixed = None
    if args.fixed_ssm:
        try:
            fixed = configure_fixed_ssm(args)
        except AccessError as exc:
            print(f"cluster-access: {exc}", file=sys.stderr)
            return 1
    if args.talos_config and not fixed:
        try:
            direct_talosconfig(args)
            return 0
        except (AccessError, OSError, ValueError, subprocess.TimeoutExpired) as exc:
            print(f"cluster-access: {exc if isinstance(exc, AccessError) else 'unable to generate direct talosconfig'}",
                  file=sys.stderr)
            return 1
    if args.ensure or args.exec_credential or (args.talos_config and args.ready_file is None):
        forwarded = [arg for arg in sys.argv[1:] if arg not in ("--ensure", "--exec-credential")]
        try:
            code = (exec_credential if args.exec_credential else ensure_access)(args, forwarded)
            if code == 0 and args.transport == "ssm":
                (args.state_dir / "lease").touch()
            return code
        except KeyError as exc:
            print(f"cluster-access: {exc.args[0]}", file=sys.stderr)
            return 1
        except (AccessError, OSError, ValueError, subprocess.TimeoutExpired) as exc:
            message = exc if isinstance(exc, AccessError) else "unable to obtain protected credentials"
            print(f"cluster-access: {message}", file=sys.stderr)
            return 1
    if fixed:
        try:
            return fixed_access(args, fixed)
        except Interrupted as exc:
            return 128 + exc.signum
        except (AccessError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as exc:
            print(f"cluster-access: {exc if isinstance(exc, AccessError) else type(exc).__name__}", file=sys.stderr)
            return 1
if __name__ == "__main__":
    sys.exit(main())
