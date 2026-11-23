#!/usr/bin/env python3
"""Open a caller-owned Talos tunnel using fixed-destination SSM Session documents."""

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

from cluster_access import (
    Access, AccessError, ControllerNotFound, Interrupted, background, interrupted, require_free_port,
)


class OperatorAccess(Access):
    def verify_host(self):
        args = self.args
        hosts = self.instances([f"Name=instance-id,Values={args.host}",
                                f"Name=vpc-id,Values={args.vpc_id}",
                                "Name=instance-state-name,Values=running"])
        for host in hosts:
            if host["InstanceId"] != args.host or host["VpcId"] != args.vpc_id:
                continue
            name = next((tag["Value"] for tag in host.get("Tags", []) if tag["Key"] == "Name"), "")
            expected = name.startswith("nat-") if args.nat_host else name == f"{args.cluster}-ssm-tunnel"
            if expected:
                break
        else:
            raise AccessError(f"Expected running {'NAT' if args.nat_host else 'jump'} host "
                              f"{args.host} in VPC {args.vpc_id}")
        info = self.aws("ssm", "describe-instance-information", "--filters",
                        json.dumps([{"Key": "InstanceIds", "Values": [args.host]}]))
        if not any(node["InstanceId"] == args.host and node["PingStatus"] == "Online"
                   for node in info["InstanceInformationList"]):
            raise AccessError(f"Host {args.host} is offline in SSM. Verify its agent, profile and routes.")

    def discover(self, states=("running",)):
        args = self.args
        controllers = [node for node in self.controllers(states)
                       if node["VpcId"] == args.vpc_id and node["PrivateIpAddress"] == args.controller_ip]
        if len(controllers) != 1:
            raise ControllerNotFound(f"Expected one {args.cluster} controller at {args.controller_ip} "
                                     f"in {args.vpc_id}; found {len(controllers)}")
        return [args.controller_ip], [args.host]

    def forward(self, target, private_ip, directory, local_port, remote_port):
        api = {6443: "kube", 50000: "talos"}[remote_port]
        self.start_session(target, directory, f"{self.args.cluster}-{api}-forward",
                           {"localPortNumber": [str(local_port)]})


def wait_for_listeners(args, access, ports):
    deadline = time.monotonic() + args.ready_timeout
    while time.monotonic() < deadline:
        if any(process.poll() is not None for process, _ in access.sessions):
            raise AccessError("SSM session exited. Verify the selected role can use this target and document.")
        try:
            for port, _ in ports:
                with socket.create_connection(("127.0.0.1", port), timeout=1):
                    pass
        except OSError:
            time.sleep(0.2)
        else:
            return
    raise AccessError("SSM local listeners did not start before the readiness deadline.")


def operator_tunnel(args, access):
    _, targets = access.discover()
    ports = [(args.kube_port, 6443)]
    if args.mode == "recovery":
        ports.append((args.talos_port, 50000))
    for port, _ in ports:
        require_free_port(port)

    args.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="tunnel-", dir=args.state_dir) as temporary:
        try:
            access.targets.add(targets[0])
            for local_port, remote_port in ports:
                access.forward(targets[0], args.controller_ip, Path(temporary), local_port, remote_port)
            wait_for_listeners(args, access, ports)
            for local_port, remote_port in ports:
                print(f"127.0.0.1:{local_port} -> {args.controller_ip}:{remote_port} via {targets[0]}")
            print("Keep this process running. Ctrl-C closes its sessions.", flush=True)
            while all(process.poll() is None for process, _ in access.sessions):
                time.sleep(0.5)
            raise AccessError("An SSM session exited. Restart the tunnel to reconnect.")
        finally:
            for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                signal.signal(signum, signal.SIG_IGN)
            access.close_forwards()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("bootstrap", "operator", "recovery"))
    parser.add_argument("--cluster", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--account-id", required=True)
    parser.add_argument("--vpc-id", required=True)
    parser.add_argument("--controller-ip", type=ipaddress.IPv4Address, required=True)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--jump-host")
    target.add_argument("--nat-host", help="Explicit NAT selection for recovery")
    parser.add_argument("--kube-port", type=int, default=16443)
    parser.add_argument("--talos-port", type=int, default=50000)
    parser.add_argument("--wait", type=int, default=900, help="Bootstrap controller discovery deadline")
    parser.add_argument("--ready-timeout", type=int, default=30, help="Local listener deadline")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}", args.cluster):
        parser.error("--cluster must be a name valid in an SSM document")
    if not re.fullmatch(r"[0-9]{12}", args.account_id) or not re.fullmatch(r"vpc-[0-9a-f]+", args.vpc_id):
        parser.error("--account-id and --vpc-id must identify an AWS account and VPC")
    args.host = args.jump_host or args.nat_host
    if not re.fullmatch(r"i-(?:[0-9a-f]{8}|[0-9a-f]{17})", args.host):
        parser.error("The target must be an EC2 instance ID")
    if args.nat_host and args.mode != "recovery":
        parser.error("--nat-host requires recovery mode")
    if any(not 1 <= port <= 65535 for port in (args.kube_port, args.talos_port)):
        parser.error("Local ports must be between 1 and 65535")
    if args.mode == "recovery" and args.kube_port == args.talos_port:
        parser.error("Recovery needs two distinct local ports")
    if not (0 < args.wait <= 1800 and 0 < args.ready_timeout <= 300):
        parser.error("--wait and --ready-timeout must be positive and bounded at 1800 and 300 seconds")
    for binary in ("aws", "session-manager-plugin"):
        if not shutil.which(binary):
            parser.error(f"Required executable missing: {binary}")

    os.umask(0o077)
    args.controller_ip = str(args.controller_ip)
    state_home = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
    identity = hashlib.sha256(f"{args.account_id}:{args.region}:{args.profile}".encode()).hexdigest()
    args.state_dir = state_home / "talos-operator-tunnel" / args.cluster / identity
    args.control_plane_name = None
    args.terragrunt_hook = args.mode == "bootstrap"
    args.parent = None
    access = OperatorAccess(args)
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    try:
        account = access.aws("sts", "get-caller-identity")["Account"]
        if account != args.account_id:
            raise AccessError(f"AWS profile {args.profile} resolves to account {account}; expected {args.account_id}")
        access.verify_host()
        if args.mode == "bootstrap":
            return background(args, access)
        operator_tunnel(args, access)
    except Interrupted as exc:
        return 128 + exc.signum
    except (AccessError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as exc:
        print(f"operator-tunnel: {exc if isinstance(exc, AccessError) else type(exc).__name__}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
