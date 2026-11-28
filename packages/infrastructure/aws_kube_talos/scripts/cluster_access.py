#!/usr/bin/env python3
"""Resolve Talos and Kubernetes access over private routing or public bootstrap."""

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
import ssl
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit


class AccessError(Exception):
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


def client_endpoint(host, port):
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


def talosconfig(args, directory, private_ip, endpoints):
    path = directory / "talosconfig"
    source = args.source_talosconfig
    private_write(path, source.read_bytes() if source else terragrunt_output(args, directory, "talosconfig"))
    # talosctl rewrites its own YAML; the CA is a single base64 scalar in the context.
    command(["talosctl", "--talosconfig", str(path), "config", "endpoint", *endpoints])
    command(["talosctl", "--talosconfig", str(path), "config", "node", private_ip])
    match = re.search(r"^\s+ca:\s*(\S+)\s*$", path.read_text(), re.MULTILINE)
    if match is None:
        raise AccessError("Terragrunt talosconfig has no embedded CA")
    ssl.create_default_context(
        cadata=base64.b64decode(match.group(1), validate=True).decode("ascii"))
    path.chmod(0o600)
    return path


def read_state(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def replace_json(path, value):
    # Unique temp name so concurrent writers never share or corrupt a file.
    pending = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    pending.unlink(missing_ok=True)
    private_write(pending, json.dumps(value).encode())
    pending.replace(path)


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
    exec_info = json.loads(os.environ.get("KUBERNETES_EXEC_INFO", "{}"))
    cluster = exec_info.get("spec", {}).get("cluster") or {}
    # NOTE: A rebuilt cluster can use the same caller and name with a new CA.
    ca = cluster.get("certificate-authority-data")
    identity = vpn_cache_key(args, ca) if ca else vpn_cache_key(args)
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
        endpoints = [client_endpoint(args.bootstrap_public_host, 50000)[0]]
    else:
        node = args.node or args.talos_endpoint[0]
        if args.talos_hostname:
            endpoints = [client_endpoint(args.talos_hostname, 50000)[0]]
        else:
            endpoints = [node] if args.node in args.talos_endpoint else args.talos_endpoint
    path = directory / f"talosconfig-{vpn_cache_key(args, node, endpoints, str(args.source_talosconfig))}"
    with tempfile.TemporaryDirectory(dir=directory) as temporary:
        config = talosconfig(args, Path(temporary), node, endpoints)
        config.replace(path)
    print(path)


def exec_credential(args):
    print(json.dumps({"apiVersion": "client.authentication.k8s.io/v1", "kind": "ExecCredential",
                      "status": vpn_credential(args)}))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
                                     allow_abbrev=False)
    parser.add_argument("--cluster",
                        help="Terraform cluster Name prefix (default: TF_VAR_cluster_name)")
    parser.add_argument("--profile", help="AWS profile (default: AWS environment)")
    parser.add_argument("--region", help="AWS region (default: AWS environment)")
    # NOTE: Generated kubeconfig exec arguments still pass these unused ports.
    parser.add_argument("--kube-port", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--talos-port", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--module", type=Path, default=Path.cwd(),
                        help="terragrunt caller directory for the outputs (default: current directory)")
    parser.add_argument("--source-kubeconfig", type=Path,
                        help="local kubeconfig to use instead of the terragrunt output")
    parser.add_argument("--source-talosconfig", type=Path,
                        help="local Talos credentials to use instead of the terragrunt output")
    parser.add_argument("--state-dir", type=Path,
                        help="credential cache (default: ${XDG_STATE_HOME:-~/.local/state}/talos-cluster-access/CLUSTER)")
    parser.add_argument("--exec-credential", action="store_true",
                        help="kubectl exec plugin: print an ExecCredential for the selected transport")
    parser.add_argument("--transport", choices=("vpn", "bootstrap_public"), default="vpn",
                        help="direct VPN or public bootstrap access (default: vpn)")
    parser.add_argument("--talos-config", action="store_true", help="print the path of a protected talosconfig")
    parser.add_argument("--talos-endpoint", action="append", help="private controller IP; repeatable with --talos-config")
    parser.add_argument("--talos-hostname", help="stable API hostname for VPN --talos-config")
    parser.add_argument("--bootstrap-public-host", help="public load balancer hostname for --talos-config")
    parser.add_argument("--node", help="private Talos node IP for --talos-config")
    args = parser.parse_args()  # --help exits before credentials, AWS or tool discovery.
    if args.cluster is None:
        # Terragrunt v0.69.1 exports string inputs without JSON quotes.
        args.cluster = os.environ.get("TF_VAR_cluster_name")
    if not args.cluster or not args.cluster.strip():
        parser.error("Set --cluster or declare inputs.cluster_name (TF_VAR_cluster_name)")
    if args.cluster in (".", "..") or any(char in args.cluster for char in "/\\*?,"):
        parser.error("Cluster name must be a single name without path separators, AWS wildcards or commas")
    if not (args.exec_credential or args.talos_config):
        parser.error("direct access uses --exec-credential or --talos-config")
    if args.bootstrap_public_host and not (args.transport == "bootstrap_public" and args.talos_config):
        parser.error("--bootstrap-public-host requires --transport bootstrap_public --talos-config")
    if args.talos_hostname and not (args.transport == "vpn" and args.talos_config and is_dns_name(args.talos_hostname)
                                    and not is_ip(args.talos_hostname)):
        parser.error("--talos-hostname requires a DNS hostname and --transport vpn --talos-config")
    if args.talos_config:
        if args.exec_credential:
            parser.error("--talos-config excludes --exec-credential")
        if args.transport == "vpn" and (not args.talos_endpoint or not all(map(is_private_ip, args.talos_endpoint))):
            parser.error("--talos-config requires private controller IPs in --talos-endpoint")
        if args.transport == "bootstrap_public":
            try:
                validate_public_endpoint(args.bootstrap_public_host, args.node)
            except AccessError as exc:
                parser.error(str(exc))
        if args.node is not None and not is_private_ip(args.node):
            parser.error("--node must be a private IP")
    elif args.talos_endpoint or args.node or args.source_talosconfig:
        parser.error("--talos-endpoint, --node and --source-talosconfig require --talos-config")
    if args.talos_config:
        binaries = ("talosctl",) + (("terragrunt",) if args.source_talosconfig is None else ())
    else:
        binaries = ("kubectl", "openssl") + (("terragrunt",) if args.source_kubeconfig is None else ())
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
    if args.talos_config:
        try:
            direct_talosconfig(args)
            return 0
        except (AccessError, OSError, ValueError, subprocess.TimeoutExpired) as exc:
            print(f"cluster-access: {exc if isinstance(exc, AccessError) else 'unable to generate direct talosconfig'}",
                  file=sys.stderr)
            return 1
    try:
        return exec_credential(args)
    except KeyError as exc:
        print(f"cluster-access: {exc.args[0]}", file=sys.stderr)
        return 1
    except (AccessError, OSError, ValueError, subprocess.TimeoutExpired) as exc:
        message = exc if isinstance(exc, AccessError) else "unable to obtain protected credentials"
        print(f"cluster-access: {message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
