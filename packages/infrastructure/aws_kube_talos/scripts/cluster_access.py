#!/usr/bin/env python3
"""Foreground, certificate-verified Kubernetes access through an Online SSM host.

Requires the AWS CLI, Session Manager plugin, terragrunt, kubectl and talosctl.
Run it from the terragrunt caller directory of the cluster or pass --module. No
infrastructure is applied or changed. The tunnel host is an SSM Online instance
in the controller VPC whose Name matches --tunnel-name-pattern, or one of the
--target instance IDs. --bootstrap instead forwards only the Talos port to a
controller that may still be pending, for the first apply of a new cluster
(needs aws and the plugin only); with --background it detaches and exits with its
parent process, for a terragrunt before_hook. A talosconfig (endpoint 127.0.0.1:<talos-port>,
node = controller private IP) is written next to the kubeconfig; the Talos API
certificate carries SAN 127.0.0.1, so it verifies without --insecure.
"""

import argparse
import base64
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import uuid


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


def stop_group(process, group=True):
    # The process-group leader may have exited while its plugin is still alive.
    # Forwards share the daemon's group, so they are signalled individually.
    send = os.killpg if group else os.kill
    try:
        send(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    # A reaped pid may be reused, so never signal a single process after wait().
    if group or process.poll() is None:
        try:
            send(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    process.wait()


def die_with_parent():
    # Forwards stay in the daemon's group; this also ends them if the daemon is SIGKILLed.
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

    def aws(self, *args):
        return json.loads(command(self.aws_args(*args, "--output", "json")))

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

    def discover(self, states=("running",)):
        controllers = self.controllers(states)
        if not controllers:
            raise ControllerNotFound(f"Expected a {'/'.join(states)} control plane named "
                                     f"{self.args.control_plane_name or self.args.cluster + '-control-plane-*'}; "
                                     "found none")
        private_ips = [str(ipaddress.IPv4Address(node["PrivateIpAddress"])) for node in controllers]
        if self.args.target:
            return private_ips, list(self.args.target)
        controller = controllers[0]
        pattern = self.args.tunnel_name_pattern
        # The module's jump host has an exact Name; the cluster name must not widen the lookup.
        if any(char in self.args.cluster for char in "*?\\,"):
            raise AccessError("Cluster name must be exact, without AWS wildcards")
        jump_name = f"{self.args.cluster}-ssm-tunnel"
        nats = self.instances([f"Name=vpc-id,Values={controller['VpcId']}",
                               "Name=instance-state-name,Values=running",
                               f"Name=tag:Name,Values={jump_name},{pattern}"])
        online = set()
        # SSM returns only managed instances; NAT EC2 running status is insufficient.
        for offset in range(0, len(nats), 50):
            ids = [node["InstanceId"] for node in nats[offset:offset + 50]]
            if not ids:
                continue
            info = self.aws("ssm", "describe-instance-information", "--filters",
                            json.dumps([{"Key": "InstanceIds", "Values": ids}]))
            online.update(node["InstanceId"] for node in info["InstanceInformationList"]
                          if node["PingStatus"] == "Online")

        def is_jump(node):
            return any(tag["Key"] == "Name" and tag["Value"] == jump_name for tag in node.get("Tags", []))
        # The module's jump host first, then other hosts; each group by instance ID.
        candidates = [node["InstanceId"] for node in
                      sorted((node for node in nats if node["InstanceId"] in online),
                             key=lambda node: (not is_jump(node), node["InstanceId"]))]
        if not candidates:
            raise NoTunnelHost(f"No SSM Online tunnel host found in control-plane VPC "
                              f"{controller['VpcId']} (running Name={jump_name} or Name={pattern} "
                              f"instances: {len(nats)}). "
                              "Restore its SSM registration/connectivity or pass --target; "
                              "this helper does not modify IAM or networking.")
        return private_ips, candidates

    def close_forwards(self):
        for process, _log in self.sessions:
            stop_group(process, group=False)
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

    def forward(self, target, private_ip, directory, local_port, remote_port):
        self.start_session(target, directory, "AWS-StartPortForwardingSessionToRemoteHost",
                           {"host": [private_ip], "portNumber": [str(remote_port)],
                            "localPortNumber": [str(local_port)]})

    def start_session(self, target, directory, document, parameters):
        log = tempfile.TemporaryFile(dir=directory)
        try:
            process = subprocess.Popen(
                self.aws_args("ssm", "start-session", "--target", target,
                              "--reason", self.reason, "--document-name", document, "--parameters",
                              json.dumps(parameters)), stdout=log, stderr=log,
                stdin=subprocess.DEVNULL, preexec_fn=die_with_parent)
        except BaseException:
            log.close()
            raise
        self.sessions.append((process, log))

    def start(self, target, private_ip, directory, tls_context, talos_tls=None):
        self.targets.add(target)
        for local_port, remote_port in ((self.args.kube_port, 6443), (self.args.talos_port, 50000)):
            self.forward(target, private_ip, directory, local_port, remote_port)
        deadline = time.monotonic() + self.args.ready_timeout
        while time.monotonic() < deadline:
            if any(process.poll() is not None for process, _ in self.sessions):
                raise AccessError("SSM forwarding process exited during startup")
            try:
                with socket.create_connection(("127.0.0.1", self.args.talos_port), timeout=1) as connection:
                    if talos_tls is not None:
                        with talos_tls.wrap_socket(connection, server_hostname="127.0.0.1"):
                            pass
                with socket.create_connection(("127.0.0.1", self.args.kube_port), timeout=1) as connection:
                    with tls_context.wrap_socket(connection, server_hostname="127.0.0.1"):
                        pass
                if all(process.poll() is None for process, _ in self.sessions):
                    return
            except (OSError, ssl.SSLError):
                pass
            time.sleep(0.2)
        raise AccessError("Timed out waiting for forwards and certificate-verified TLS")

    def establish(self, private_ips, candidates, directory, tls_context, talos_tls, on_ready):
        # One pass over the NATs; per NAT, controllers are tried in position order so an
        # unhealthy one falls through to the next.
        for target in candidates:
            for private_ip in private_ips:
                try:
                    self.start(target, private_ip, directory, tls_context, talos_tls)
                except AccessError as exc:
                    print(f"NAT {target} controller {private_ip}: {exc}; trying next", file=sys.stderr)
                    self.close_forwards()
                    continue
                on_ready(private_ip)
                return target, private_ip
        raise AccessError("All SSM Online NAT candidates failed to establish both forwards")

    def wait_for_talos_forward(self):
        deadline = time.monotonic() + self.args.ready_timeout
        while time.monotonic() < deadline:
            if any(process.poll() is not None for process, _ in self.sessions):
                raise AccessError("SSM forwarding process exited during startup")
            try:
                # The controller may still be booting: a TCP accept is the only possible check.
                with socket.create_connection(("127.0.0.1", self.args.talos_port), timeout=1):
                    return
            except OSError:
                time.sleep(0.2)
        raise AccessError("Timed out waiting for the Talos forward to accept connections")


def private_write(path, content):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(content)


def terragrunt_output(args, directory, name):
    # A private download dir avoids the shared .terragrunt-cache, whose stale
    # copies make terragrunt fail with duplicate definitions.
    download = directory / "terragrunt-download"
    env = dict(os.environ, TERRAGRUNT_DOWNLOAD=str(download), TG_DOWNLOAD_DIR=str(download))
    try:
        return command(["terragrunt", "output", "-raw", name], cwd=args.module, env=env)
    finally:
        shutil.rmtree(download, ignore_errors=True)


def kubeconfig(args, directory):
    source = directory / "source-kubeconfig"
    if args.source_kubeconfig is not None:
        private_write(source, args.source_kubeconfig.read_bytes())
    else:
        private_write(source, terragrunt_output(args, directory, "kubeconfig"))
    # kubectl supplies the YAML parser; the Python implementation is stdlib only.
    config = json.loads(command(["kubectl", "--kubeconfig", str(source), "config", "view",
                                 "--raw", "--flatten", "-o", "json"]))
    source.unlink()
    context = next((item["context"] for item in config.get("contexts", [])
                    if item["name"] == config.get("current-context")), None)
    if context is None:
        raise AccessError("Terragrunt kubeconfig has no current context")
    cluster = next((item["cluster"] for item in config.get("clusters", [])
                    if item["name"] == context["cluster"]), None)
    if cluster is None or not cluster.get("certificate-authority-data"):
        raise AccessError("Terragrunt kubeconfig has no embedded cluster CA")
    cluster.pop("insecure-skip-tls-verify", None)
    cluster["server"] = f"https://127.0.0.1:{args.kube_port}"
    # A source proxy would bypass the local forward.
    cluster.pop("proxy-url", None)
    tls_context = ssl.create_default_context(
        cadata=base64.b64decode(cluster["certificate-authority-data"], validate=True).decode("ascii"))
    path = directory / "kubeconfig.json"
    private_write(path, json.dumps(config).encode())
    return path, tls_context


def talosconfig(args, directory, private_ip):
    path = directory / "talosconfig"
    private_write(path, terragrunt_output(args, directory, "talosconfig"))
    # talosctl rewrites its own YAML; the CA is a single base64 scalar in the context.
    command(["talosctl", "--talosconfig", str(path), "config", "endpoint",
             f"127.0.0.1:{args.talos_port}"])
    command(["talosctl", "--talosconfig", str(path), "config", "node", private_ip])
    match = re.search(r"^\s+ca:\s*(\S+)\s*$", path.read_text(), re.MULTILINE)
    if match is None:
        raise AccessError("Terragrunt talosconfig has no embedded CA")
    tls_context = ssl.create_default_context(
        cadata=base64.b64decode(match.group(1), validate=True).decode("ascii"))
    return path, tls_context


def require_free_port(port):
    # Refuse existing listeners, rather than mistaking someone else's tunnel
    # for our own or killing a process we did not create.
    with socket.socket() as probe:
        try:
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


def forward_talos(args, access, candidates, private_ip, directory):
    for target in candidates:
        access.targets.add(target)
        try:
            access.forward(target, private_ip, directory, args.talos_port, 50000)
            access.wait_for_talos_forward()
            return target
        except AccessError as exc:
            print(f"Tunnel host {target}: {exc}; trying next Online tunnel host", file=sys.stderr)
            access.close_forwards()
    raise AccessError("All SSM Online tunnel hosts failed to establish the Talos forward")


def bootstrap(args, access):
    require_free_port(args.talos_port)
    private_ip, candidates = wait_for_controller(args, access)
    require_free_port(args.talos_port)
    with tempfile.TemporaryDirectory(prefix="cluster-access-") as directory:
        target = forward_talos(args, access, candidates, private_ip, Path(directory))
        print(f"Controller private IP: {private_ip}")
        print(f"NAT target: {target}")
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
    failures = 0
    with tempfile.TemporaryDirectory(prefix="cluster-access-") as directory:
        try:
            # A first apply must be able to create the controller and the SSM host.
            if initial is None:
                ready()
            while True:
                started = None
                try:
                    private_ip, candidates = initial or wait_for_controller(args, access)
                    require_free_port(args.talos_port)
                    target = forward_talos(args, access, candidates, private_ip, Path(directory))
                    started = time.monotonic()
                    print(f"Forwarding Talos to {private_ip} through {target}", flush=True)
                    if initial is not None:
                        ready()
                        initial = None
                    while all(process.poll() is None for process, _ in access.sessions):
                        nap(args, 0.5)
                    raise AccessError("The SSM forward exited")
                except WaitTimeout as exc:
                    # A plan of a cluster that does not exist yet needs no Talos tunnel.
                    print(f"cluster-access: {exc}", file=sys.stderr, flush=True)
                    return 0
                except AccessError as exc:
                    if initial is not None:
                        raise
                    print(f"cluster-access: {exc}", file=sys.stderr, flush=True)
                    access.close_forwards()
                    if started is not None and time.monotonic() - started > 60:
                        failures = 0
                    failures += 1
                    if failures > 5:
                        raise
                    # The controller may have been replaced or stopped; discover it again.
                    nap(args, min(2 ** failures, 30))
        finally:
            for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                signal.signal(signum, signal.SIG_IGN)
            access.close_forwards()


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
            {"pid": os.getpid(), "parent": parent, "talos_port": args.talos_port}).encode())
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
    """Start the Talos-only forward detached from a terragrunt before_hook; return fast."""
    directory = args.state_dir
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    parent = os.getppid()
    port = args.talos_port
    # The lock only serializes concurrent hooks around the decision and the record write.
    with (directory / "bootstrap.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        ready = read_state(directory / "ready.json")
        if isinstance(ready, dict) and ready.get("talos_port") == port and alive(ready.get("pid")):
            if args.terragrunt_hook:
                raise AccessError(f"Local Talos port {port} is reserved by an operator tunnel; stop that tunnel first")
            print(f"reusing live tunnel for {args.cluster} on 127.0.0.1:{port}")
            return 0
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


def process_table():
    # Same columns on Linux and macOS; the full command line carries the SSM reason.
    try:
        output = subprocess.run(["ps", "-eo", "pid,pgid,args"], capture_output=True, text=True,
                                timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    rows = []
    for line in output.splitlines()[1:]:
        fields = line.split(None, 2)
        if len(fields) == 3 and fields[0].isdigit() and fields[1].isdigit():
            rows.append((int(fields[0]), int(fields[1]), fields[2]))
    return rows


def owned_forwards(args):
    # Ownership is the SSM reason of this cluster. The 32 hex digits keep a cluster
    # whose name prefixes another (talos, talos-2) from matching the other's reason.
    reason = re.compile(rf"(?<![\w-])cluster-access-{re.escape(args.cluster)}-[0-9a-f]{{32}}(?!\w)")
    port = re.compile(r'"localPortNumber\\?":\s*\[\s*\\?"(\d+)\\?"')
    target = re.compile(r"--target\s+(\S+)|\\?\"Target\\?\":\s*\\?\"([^\\\"]+)")
    host = re.compile(r'"host\\?":\s*\[\s*\\?"([^\\"]+)')
    forwards = []
    for pid, _pgid, line in process_table():
        found, number = reason.search(line), port.search(line)
        if pid == os.getpid() or not found or not number:
            continue
        where, node = target.search(line), host.search(line)
        forwards.append({"pid": pid, "reason": found.group(0), "port": int(number.group(1)),
                         "target": where and (where.group(1) or where.group(2)),
                         "host": node and node.group(1)})
    return forwards


def listener_pids(port):
    pids = set()
    if sys.platform.startswith("linux"):
        try:
            output = subprocess.run(["ss", "-ltnp"], capture_output=True, text=True, timeout=10).stdout
        except (OSError, subprocess.TimeoutExpired):
            output = ""
        for line in output.splitlines():
            fields = line.split()
            if len(fields) > 3 and fields[3].endswith(f":{port}"):
                pids.update(int(pid) for pid in re.findall(r"pid=(\d+)", line))
    if not pids:
        try:
            output = subprocess.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
                                    capture_output=True, text=True, timeout=10).stdout
        except (OSError, subprocess.TimeoutExpired):
            output = ""
        pids.update(int(item) for item in output.split() if item.isdigit())
    return pids


def process_name(pid):
    try:
        output = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True,
                                timeout=10).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        output = ""
    return Path(output).name or "unknown"


def port_listening(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return True
    except OSError:
        return False


def tls_verifies(port, tls_context):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
            with tls_context.wrap_socket(connection, server_hostname="127.0.0.1"):
                return True
    except (OSError, ssl.SSLError):
        return False


def reap_forwards(args, forwards):
    # Only processes whose args carry this cluster's reason; SIGKILL re-checks that
    # after the grace period so a reused pid is never signalled.
    pids = {item["pid"] for item in forwards}
    for pid in sorted(pids):
        try:
            os.kill(pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
    deadline = time.monotonic() + 3
    while any(alive(pid) for pid in pids) and time.monotonic() < deadline:
        time.sleep(0.1)
    for pid in sorted(pids & {item["pid"] for item in owned_forwards(args)}):
        try:
            os.kill(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    # A killed forward cannot terminate its remote session; close each by exact reason.
    for reason in sorted({item["reason"] for item in forwards}):
        access = Access(args)
        access.reason = reason
        access.targets = {item["target"] for item in forwards if item["reason"] == reason and item["target"]}
        access.close_forwards()


def adopt_or_clear_ports(args, state, directory):
    """Return a kubeconfig path for an adopted tunnel, or None when both ports are free to use."""
    owned = owned_forwards(args)
    if not port_listening(args.kube_port):
        stray = [item for item in owned if item["port"] == args.talos_port]
        if stray and port_listening(args.talos_port):
            reap_forwards(args, stray)
        return None
    kube = [item for item in owned if item["port"] == args.kube_port]
    holders = listener_pids(args.kube_port)
    mine = [item for item in kube if not holders or item["pid"] in holders]
    if not mine:
        pid = min(holders) if holders else None
        raise AccessError(f"port {args.kube_port} is held by PID {pid or 'unknown'} "
                          f"({process_name(pid) if pid else 'unknown'}); not a tunnel for {args.cluster}")
    adopted = directory / "adopted"
    shutil.rmtree(adopted, ignore_errors=True)
    adopted.mkdir(mode=0o700)
    talos = next((item for item in owned if item["port"] == args.talos_port and item["host"]), None)
    config, tls_context = kubeconfig(args, adopted)
    healthy = talos is not None and tls_verifies(args.kube_port, tls_context)
    talos_path = None
    if healthy and args.source_kubeconfig is None:
        talos_path, talos_tls = talosconfig(args, adopted, talos["host"])
        healthy = tls_verifies(args.talos_port, talos_tls)
    elif healthy:
        healthy = port_listening(args.talos_port)
    if not healthy:
        # Our own forward fails certificate verification, so it is replaced.
        shutil.rmtree(adopted, ignore_errors=True)
        reap_forwards(args, [item for item in owned if item["port"] in (args.kube_port, args.talos_port)])
        return None
    pending = state.with_suffix(".tmp")
    pending.unlink(missing_ok=True)
    private_write(pending, json.dumps(
        {"pid": mine[0]["pid"], "kubeconfig": str(config), "talosconfig": str(talos_path) if talos_path else None,
         "cluster": args.cluster, "kube_port": args.kube_port, "talos_port": args.talos_port,
         "adopted": True}).encode())
    pending.replace(state)
    return str(config)


def ensure_access(args, forwarded):
    directory = args.state_dir
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    state = directory / "ready.json"
    with (directory / "startup.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if state.exists():
            ready = json.loads(state.read_text())
            try:
                os.kill(ready["pid"], 0)
            except ProcessLookupError:
                state.unlink()
            else:
                if not Path(ready["kubeconfig"]).is_file():
                    raise AccessError("Existing tunnel is closing; reload direnv after it exits")
                # One slow probe over a busy SSM stream is not a dead controller; killing
                # the shared tunnel on it breaks every in-flight apply.
                for _ in range(3):
                    try:
                        command(["kubectl", "--kubeconfig", ready["kubeconfig"],
                                 "--request-timeout=15s", "get", "--raw=/readyz"], timeout=20)
                    except (AccessError, subprocess.TimeoutExpired):
                        time.sleep(2)
                        continue
                    args.report(ready["kubeconfig"])
                    return 0
                else:
                    # Its controller is gone (stopped or replaced); replace the tunnel with one to a live controller.
                    if ready.get("adopted"):
                        # No daemon owns these forwards, so there is no group to signal.
                        reap_forwards(args, owned_forwards(args))
                    else:
                        os.killpg(ready["pid"], signal.SIGTERM)
                        deadline = time.monotonic() + 30
                        while state.exists() and time.monotonic() < deadline:
                            time.sleep(0.2)
                    state.unlink(missing_ok=True)
        adopted = adopt_or_clear_ports(args, state, directory)
        if adopted is not None:
            args.report(adopted)
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
                    args.report(json.loads(state.read_text())["kubeconfig"])
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
        status = {key: cache[key] for key in ("clientCertificateData", "clientKeyData")}
    except (OSError, ValueError, KeyError, StopIteration, TypeError, ssl.SSLError):
        return None
    if not all(isinstance(value, str) for value in status.values()):
        return None
    return status if tls_verifies(args.kube_port, tls_context) else None


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


def exec_credential(args, forwarded):
    status = warm_credential(args)
    if status is None:
        paths = []
        args.report = paths.append
        code = ensure_access(args, forwarded)
        if code:
            return code
        # The tunnel kubeconfig is JSON when we wrote it, but a legacy one may be YAML.
        raw = command(["kubectl", "--kubeconfig", paths[0], "config", "view",
                       "--raw", "--flatten", "-o", "json"])
        config = json.loads(raw)
        context = next(item["context"] for item in config["contexts"]
                       if item["name"] == config["current-context"])
        user = next(item["user"] for item in config["users"] if item["name"] == context["user"])
        status = {}
        for key, field in (("clientCertificateData", "client-certificate-data"),
                           ("clientKeyData", "client-key-data")):
            status[key] = base64.b64decode(user[field], validate=True).decode("ascii")
        # ensure_access just proved the tunnel healthy, so the next call can skip the probe.
        replace_json(args.state_dir / "credential.json", {**status, "kubeconfig": paths[0]})
        mark_ok(args.state_dir / "ready.json")
    print(json.dumps({"apiVersion": "client.authentication.k8s.io/v1", "kind": "ExecCredential",
                      "status": status}))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cluster", required=True,
                        help="Terraform cluster Name prefix; controllers are CLUSTER-control-plane-{0..2}")
    parser.add_argument("--control-plane-name", help="exact EC2 Name instead of every CLUSTER-control-plane-* controller")
    parser.add_argument("--profile", help="AWS profile (default: AWS environment)")
    parser.add_argument("--region", help="AWS region (default: AWS environment)")
    parser.add_argument("--kube-port", type=int, default=16443, help="local Kubernetes API port (default: 16443)")
    parser.add_argument("--talos-port", type=int, default=50000, help="local Talos API port (default: 50000)")
    parser.add_argument("--module", type=Path, default=Path.cwd(),
                        help="terragrunt caller directory for the outputs (default: current directory)")
    parser.add_argument("--source-kubeconfig", type=Path,
                        help="local kubeconfig to use instead of the terragrunt output")
    parser.add_argument("--tunnel-name-pattern", default="nat-*",
                        help="Name tag of the tunnel hosts in the controller VPC (default: nat-*)")
    parser.add_argument("--target", action="append", metavar="INSTANCE_ID",
                        help="tunnel host instance ID, repeatable; skips discovery")
    parser.add_argument("--state-dir", type=Path,
                        help="--ensure state (default: ${XDG_STATE_HOME:-~/.local/state}/talos-cluster-access/CLUSTER)")
    parser.add_argument("--ready-timeout", type=float, default=30,
                        help="startup deadline in seconds per tunnel host (default: 30)")
    parser.add_argument("--ensure", action="store_true",
                        help="start or reuse background access and print its kubeconfig")
    parser.add_argument("--exec-credential", action="store_true",
                        help="kubectl exec plugin: ensure the tunnel, print an ExecCredential")
    parser.add_argument("--bootstrap", action="store_true",
                        help="wait for a pending or running controller and forward only its Talos port")
    parser.add_argument("--wait", type=float, default=900,
                        help="--bootstrap: seconds to wait for the controller (default: 900)")
    parser.add_argument("--background", action="store_true",
                        help="--bootstrap: detach and return at once; the helper exits with its parent process "
                             "(for a terragrunt before_hook)")
    parser.add_argument("--idle-timeout", type=int, default=3600,
                        help="--ensure daemon: exit after this many seconds with no successful --ensure or "
                             "--exec-credential and no open connection; 0 disables (default: 3600)")
    # Tests only: a short check interval, which also allows idle timeouts below 60 s.
    parser.add_argument("--idle-check-interval", type=float, help=argparse.SUPPRESS)
    parser.add_argument("--ready-file", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()  # --help exits before credentials, AWS or tool discovery.
    args.terragrunt_hook = False
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
    for binary in ("aws", "session-manager-plugin", "kubectl",
                   *(("terragrunt", "talosctl") if args.source_kubeconfig is None and not args.bootstrap else ())):
        if not shutil.which(binary):
            if args.exec_credential:
                print(f"cluster-access: required executable missing: {binary}", file=sys.stderr)
                return 1
            parser.error(f"Required executable missing: {binary}")
    os.umask(0o077)
    if args.state_dir is None:
        state_home = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
        args.state_dir = state_home / "talos-cluster-access" / args.cluster
    access = Access(args)
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    if args.ensure or args.exec_credential:
        forwarded = [arg for arg in sys.argv[1:] if arg not in ("--ensure", "--exec-credential")]
        try:
            code = (exec_credential if args.exec_credential else ensure_access)(args, forwarded)
            if code == 0:
                (args.state_dir / "lease").touch()
            return code
        except KeyError as exc:
            print(f"cluster-access: {exc.args[0]}", file=sys.stderr)
            return 1
        except (AccessError, OSError, ValueError, subprocess.TimeoutExpired) as exc:
            print(f"cluster-access: {exc}", file=sys.stderr)
            return 1
    try:
        if args.background:
            return background(args, access)
        if args.bootstrap:
            bootstrap(args, access)
            return 0
        private_ips, candidates = access.discover()
        for port in (args.kube_port, args.talos_port):
            require_free_port(port)
        with tempfile.TemporaryDirectory(prefix="cluster-access-") as temporary:
            directory = Path(temporary)  # mkdtemp is 0700; files are explicitly 0600.
            config, tls_context = kubeconfig(args, directory)
            talos_path, talos_tls = (talosconfig(args, directory, private_ips[0])
                                     if args.source_kubeconfig is None else (None, None))
            def on_ready(private_ip):
                # talosctl's node must name the controller the forward actually reaches.
                if talos_path is not None and private_ip != node[0]:
                    command(["talosctl", "--talosconfig", str(talos_path), "config", "node", private_ip])
                    node[0] = private_ip
            node = [private_ips[0]]
            target, private_ip = access.establish(private_ips, candidates, directory, tls_context,
                                                  talos_tls, on_ready)
            print(f"Forwarding through {target} to {private_ip}; keep this process running.")
            print(f"export KUBECONFIG={shlex.quote(str(config))}")
            print(f"Kubernetes: 127.0.0.1:{args.kube_port} -> private:6443 (verified 127.0.0.1 TLS identity)")
            if talos_path is None:
                print(f"Talos TCP: 127.0.0.1:{args.talos_port} -> private:50000; no talosconfig for a local "
                      "source kubeconfig. Do not use --insecure.")
            else:
                print(f"export TALOSCONFIG={shlex.quote(str(talos_path))}")
                print(f"Talos: 127.0.0.1:{args.talos_port} -> private:50000 (verified 127.0.0.1 TLS identity)")
            print("Ctrl-C stops owned forwards/sessions and deletes temporary credentials.", flush=True)
            if args.ready_file is not None:
                pending = args.ready_file.with_suffix(".tmp")
                pending.unlink(missing_ok=True)
                private_write(pending, json.dumps(
                    {"pid": os.getpid(), "kubeconfig": str(config), "talosconfig": str(talos_path) if talos_path else None,
                     "cluster": args.cluster, "kube_port": args.kube_port, "talos_port": args.talos_port}).encode())
                pending.replace(args.ready_file)
            last_active = time.time()
            next_idle_check = 0.0
            try:
                while True:
                    if any(process.poll() is not None for process, _ in access.sessions):
                        print("cluster-access: an SSM forward exited; restarting both forwards",
                              file=sys.stderr, flush=True)
                        access.close_forwards()
                        private_ips, candidates = access.discover()
                        # The controller may be gone or unhealthy: try the others first.
                        private_ips = rotate_after(private_ips, private_ip)
                        # Start after the failed NAT and try it last: one pass, then exit.
                        if target in candidates:
                            position = candidates.index(target) + 1
                            candidates = candidates[position:] + candidates[:position]
                        target, private_ip = access.establish(
                            private_ips, candidates, directory, tls_context, talos_tls, on_ready)
                        print(f"Forwarding through {target} to {private_ip}", flush=True)
                    if args.ready_file is not None and args.idle_timeout and time.monotonic() >= next_idle_check:
                        next_idle_check = time.monotonic() + args.idle_check_interval
                        last_active = close_when_idle(args, access, last_active)
                        if last_active is None:
                            return 0
                    time.sleep(0.5)
            finally:
                # Keep log files alive until remote-session cleanup has completed.
                for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                    signal.signal(signum, signal.SIG_IGN)
                access.close_forwards()
    except Interrupted as exc:
        return 128 + exc.signum
    except (AccessError, OSError, ValueError, KeyError, StopIteration,
            subprocess.TimeoutExpired) as exc:
        if isinstance(exc, AccessError):
            print(f"cluster-access: {exc}", file=sys.stderr)
        else:
            print(f"cluster-access: {type(exc).__name__}; unable to establish secure access "
                  "(details withheld to protect credentials)", file=sys.stderr)
        return 1
    finally:
        if args.ready_file is not None:
            args.ready_file.unlink(missing_ok=True)
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(signum, signal.SIG_IGN)
        access.close_forwards()
    return 0


if __name__ == "__main__":
    sys.exit(main())
