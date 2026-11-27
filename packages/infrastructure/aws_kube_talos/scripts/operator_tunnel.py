#!/usr/bin/env python3
"""Internal fixed-destination SSM driver for cluster_access.py."""

from http.client import HTTPException, HTTPResponse
import json
import os
import re
import signal
import socket
import subprocess
import sys
import time
from typing import NamedTuple

from cluster_access import (
    Access, AccessError, ControllerNotFound, NoTunnelHost, command, nap, require_free_port, rotate_after,
)


LOOPBACK = "127.0.0.1"
APIS = {6443: "kube", 50000: "talos"}
HOST_CHECK_INTERVAL = 15


class Destination(NamedTuple):
    name: str
    host: str
    port: int


def instance_id(value):
    return re.fullmatch(r"i-(?:[0-9a-f]{8}|[0-9a-f]{17})", value)


def hostname(value):
    if not isinstance(value, str) or len(value) > 253 or not all(
            re.fullmatch(r"[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?", label)
            for label in value.split(".")):
        raise ValueError("Expected an IPv4 address or DNS name")
    return value.lower()


def document_destinations(args):
    ports = {"operator": (6443,), "talos": (50000,)}.get(args.mode, (6443, 50000))
    if args.mode == "bootstrap" and not args.terragrunt_hook and not args.preflight:
        ports = (50000,)
    hosts = {6443: args.kube_host, 50000: args.controller_ip}
    try:
        entries = args.document_entries
        documents = [Destination(entry["name"], hostname(entry["host"]), entry["port"])
                     for entry in entries.values()]
        if any(not isinstance(doc.name, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{3,128}", doc.name)
               or type(doc.port) is not int or doc.port not in APIS for doc in documents):
            raise ValueError("Invalid document name or port")
        if len(set(doc.name for doc in documents)) != len(documents):
            raise ValueError("Document names must be distinct")
    except (AttributeError, KeyError, OSError, TypeError, ValueError) as exc:
        raise AccessError(f"Fix the document map in {args.fixed_ssm}") from exc

    selected = {}
    for port in ports:
        host = hosts[port]
        candidates = [doc for doc in documents if doc.port == port and (host is None or doc.host == host)]
        if len(candidates) != 1:
            raise AccessError(f"Expected one fixed SSM document for {APIS[port]} at {host or 'the configured endpoint'}:"
                              f"{port}; found {len(candidates)} in {args.fixed_ssm}")
        selected[port] = candidates[0]
    return selected


class OperatorAccess(Access):
    request_deadline = None

    def aws(self, *args):
        timeout = 25
        if self.request_deadline is not None:
            timeout = min(timeout, self.request_deadline - time.monotonic())
            if timeout <= 0:
                raise AccessError("AWS discovery exceeded the SSM reconnect deadline")
        return super().aws(*args, timeout=timeout)

    def prepare(self):
        args = self.args
        account = self.aws("sts", "get-caller-identity")["Account"]
        if account != args.account_id:
            raise AccessError(f"AWS profile {args.profile} resolves to account {account}; expected {args.account_id}")
        self.destinations = document_destinations(args)
        for destination in self.destinations.values():
            self.verify_document(destination)

    def verify_document(self, destination):
        try:
            response = self.aws("ssm", "get-document", "--name", destination.name,
                                "--document-version", "$DEFAULT", "--document-format", "JSON")
            content = json.loads(response["Content"])
            properties = content["properties"]
            fixed = (response["DocumentType"] == "Session"
                     and content["sessionType"] == "Port"
                     and properties["type"] == "LocalPortForwarding"
                     and set(content["parameters"]) == {"localPortNumber"}
                     and properties["localPortNumber"] == "{{ localPortNumber }}"
                     and hostname(properties["host"]) == destination.host
                     and str(properties["portNumber"]) == str(destination.port))
        except (AccessError, KeyError, OSError, TypeError, ValueError, subprocess.TimeoutExpired) as exc:
            raise AccessError(f"Could not verify default SSM document {destination.name}; "
                              "check its existence and ssm:GetDocument permission") from exc
        if not fixed:
            raise AccessError(f"Default SSM document {destination.name} does not fix the destination "
                              f"at {destination.host}:{destination.port} with only the local port configurable")

    def discover_hosts(self):
        args = self.args
        ids = [args.nat_host] if args.nat_host else args.approved_jump_host
        filters = [f"Name=instance-id,Values={','.join(ids)}", f"Name=vpc-id,Values={args.vpc_id}",
                   "Name=instance-state-name,Values=running"]
        expected_name = f"{args.cluster}-ssm-tunnel"
        if not args.nat_host:
            filters.append(f"Name=tag:Name,Values={expected_name}")
            filters.extend([f"Name=tag:panfactum.com/cluster,Values={args.cluster}",
                            "Name=tag:panfactum.com/module,Values=aws_ssm_jump_host"])
        hosts = set()
        for host in self.instances(filters):
            if (host.get("InstanceId") not in ids or host.get("VpcId") != args.vpc_id
                    or host.get("State", {}).get("Name") != "running"):
                continue
            tags = {tag["Key"]: tag["Value"] for tag in host.get("Tags", [])}
            name = tags.get("Name", "")
            if args.nat_host:
                eligible = name.startswith("nat-")
            else:
                eligible = (name == expected_name and tags.get("panfactum.com/cluster") == args.cluster
                            and tags.get("panfactum.com/module") == "aws_ssm_jump_host")
            if eligible:
                hosts.add(host["InstanceId"])
        if not hosts:
            raise NoTunnelHost(f"No approved running {'NAT' if args.nat_host else 'jump'} host "
                               f"for {args.cluster} in {args.vpc_id}")
        response = self.aws("ssm", "describe-instance-information", "--filters",
                            json.dumps([{"Key": "InstanceIds", "Values": sorted(hosts)}]))
        online = {node["InstanceId"] for node in response["InstanceInformationList"]
                  if node["PingStatus"] == "Online"}
        targets = [target for target in ids if target in hosts and target in online]
        if not targets:
            raise NoTunnelHost(f"No approved host for {args.cluster} is SSM Online in {args.vpc_id}; "
                               "check the agent, instance profile and routes")
        return targets

    def discover(self, states=("running",), *, deadline=None):
        args = self.args
        self.request_deadline = deadline
        try:
            if args.mode != "operator":
                controllers = [node for node in self.controllers(states)
                               if node["VpcId"] == args.vpc_id and node["PrivateIpAddress"] == args.controller_ip]
                if len(controllers) != 1:
                    raise ControllerNotFound(f"Expected one {args.cluster} controller at {args.controller_ip} "
                                             f"in {args.vpc_id}; found {len(controllers)}")
            targets = self.discover_hosts()
            if deadline is not None:
                for destination in self.destinations.values():
                    self.verify_document(destination)
            return [args.controller_ip], targets
        finally:
            self.request_deadline = None

    def separate_sessions(self):
        access = OperatorAccess(self.args)
        access.destinations = self.destinations
        return access

    def establish_bootstrap(self, candidates, directory, local_port, remote_port):
        try:
            return establish(self.args, self, candidates, directory, [(local_port, remote_port)])
        except NoTunnelHost as exc:
            api = "Talos" if remote_port == 50000 else "Kubernetes"
            raise AccessError(f"All approved SSM hosts failed to establish the {api} forward") from exc

    def forward(self, target, host, directory, local_port, remote_port):
        destination = self.destinations[remote_port]
        if host != destination.host:
            raise AccessError(f"Requested host does not match fixed SSM document {destination.name}")
        self.targets.add(target)
        try:
            self.start_session(target, directory, destination.name, {"localPortNumber": [str(local_port)]})
        except OSError as exc:
            raise AccessError(f"Could not start SSM document {destination.name} on {target}: {exc.strerror}") from exc

    def probe(self, local_port, remote_port, timeout):
        if remote_port == 50000:
            command(["talosctl", "--talosconfig", str(self.args.talosconfig),
                     "--endpoints", f"{LOOPBACK}:{local_port}", "--nodes", self.args.controller_ip,
                     "version", "--short"], timeout=timeout)
            return
        identity = self.args.kube_tls_name
        with socket.create_connection((LOOPBACK, local_port), timeout=timeout) as connection:
            with self.kube_tls.wrap_socket(connection, server_hostname=identity) as tls:
                tls.sendall(f"GET /readyz HTTP/1.1\r\nHost: {identity}\r\nConnection: close\r\n\r\n".encode())
                with HTTPResponse(tls) as response:
                    response.begin()
                    # NOTE: Operators may authenticate only in kubectl. An auth response proves reachability.
                    if response.status not in (200, 401, 403):
                        raise AccessError(f"Kubernetes /readyz returned HTTP {response.status}")

    def close_forwards(self):
        super().close_forwards()
        self.targets.clear()


def check_forwards(args, access, ports, deadline):
    if any(process.poll() is not None for process, _ in access.sessions):
        raise AccessError("SSM session exited; verify the selected role can use this target and document")
    for (local_port, remote_port), (_, log) in zip(ports, access.sessions, strict=True):
        # NOTE: A different process can claim the local port before the plugin binds it.
        if f"Port {local_port} opened for sessionId ".encode() not in os.pread(log.fileno(), 32768, 0):
            raise AccessError(f"Session Manager plugin did not open its listener on port {local_port}")
        if args.mode == "bootstrap":
            continue
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AccessError("Timed out probing forwarded APIs")
        try:
            access.probe(local_port, remote_port, min(3, remaining))
        except (AccessError, HTTPException, OSError, subprocess.TimeoutExpired) as exc:
            raise AccessError(f"No usable {APIS[remote_port]} API on {LOOPBACK}:{local_port}"
                              + (f" ({exc})" if isinstance(exc, AccessError) else "")) from exc


def wait_for_forwards(args, access, ports, deadline):
    deadline = min(deadline, time.monotonic() + args.ready_timeout)
    failure = None
    while time.monotonic() < deadline:
        try:
            check_forwards(args, access, ports, deadline)
        except AccessError as exc:
            failure = exc
            if any(process.poll() is not None for process, _ in access.sessions):
                break
            nap(args, min(0.2, deadline - time.monotonic()))
        else:
            return
    raise AccessError(f"Forward startup failed: {failure or 'readiness deadline expired'}") from failure


def report_forwards(access, ports, target):
    for local_port, remote_port in ports:
        destination = access.destinations[remote_port]
        print(f"{LOOPBACK}:{local_port} -> {destination.host}:{destination.port} via {target}"
              f" (SSM document {destination.name})", flush=True)


def establish(args, access, candidates, directory, ports, deadline=float("inf")):
    for target in candidates:
        if time.monotonic() >= deadline:
            break
        for local_port, _ in ports:
            require_free_port(local_port)
        try:
            for local_port, remote_port in ports:
                access.forward(target, access.destinations[remote_port].host, directory, local_port, remote_port)
            wait_for_forwards(args, access, ports, deadline)
        except (AccessError, OSError) as exc:
            print(f"SSM host {target}: {exc}; trying next approved host", file=sys.stderr)
            access.close_forwards()
        else:
            report_forwards(access, ports, target)
            return target
    raise NoTunnelHost("No approved SSM host established the required API forwards")


def monitor(args, access, target, ports, active):
    next_check = time.monotonic() + HOST_CHECK_INTERVAL
    while all(process.poll() is None for process, _ in access.sessions):
        if not active():
            return
        if time.monotonic() >= next_check:
            check_forwards(args, access, ports, time.monotonic() + 3 * len(ports))
            try:
                candidates = access.discover_hosts()
            except NoTunnelHost:
                candidates = []
            except (AccessError, subprocess.TimeoutExpired) as exc:
                print(f"Could not refresh SSM host health ({type(exc).__name__}); checking again",
                      file=sys.stderr)
                candidates = [target]
            if target not in candidates:
                raise AccessError(f"SSM host {target} is no longer eligible")
            next_check = time.monotonic() + HOST_CHECK_INTERVAL
        nap(args, 0.5)
    raise AccessError("An SSM session exited")


def reconnect(args, access, directory, ports, previous):
    deadline = time.monotonic() + args.reconnect_timeout
    while True:
        try:
            _, candidates = access.discover(deadline=deadline)
        except (AccessError, subprocess.TimeoutExpired) as exc:
            failure = str(exc) if isinstance(exc, AccessError) else "AWS discovery command timed out"
        else:
            try:
                return establish(args, access, rotate_after(candidates, previous), directory, ports, deadline)
            except NoTunnelHost as exc:
                failure = str(exc)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AccessError(f"SSM reconnect timed out: {failure}")
        nap(args, min(2, remaining))


def run_forwards(args, access, directory, ports, ready, active=lambda: True):
    try:
        _, candidates = access.discover()
        target = establish(args, access, candidates, directory, ports)
        ready()
        while True:
            try:
                monitor(args, access, target, ports, active)
                return
            except AccessError as exc:
                print(f"{exc}; reconnecting on the same ports", file=sys.stderr)
                access.close_forwards()
            target = reconnect(args, access, directory, ports, target)
    finally:
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(signum, signal.SIG_IGN)
        access.close_forwards()


if __name__ == "__main__":
    sys.exit("Use cluster_access.py with --fixed-ssm for SSM access")
