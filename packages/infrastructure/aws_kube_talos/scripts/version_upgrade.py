#!/usr/bin/env python3
"""Upgrade Talos on the controllers when the Talos version or selected schematic changes.

  version_upgrade.py talos --endpoint E --nodes IP,IP --target vX.Y.Z --image IMAGE [--schematic-id ID]

Run by terraform_data local-exec. The client certificate comes from TALOS_CA, TALOS_CRT and
TALOS_KEY (base64, as in a talosconfig), so talosctl must be on PATH and the Talos API reachable
at --endpoint. Talos OS upgrades skip nodes already running the requested image.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time

from etcd_members import parse_member_ips

POLL_SECONDS = 10
NODE_TIMEOUT = 1800


class UpgradeError(Exception):
    pass


def server_tag(output):
    # The first Tag belongs to the client; the server block starts at "Server:".
    match = re.search(r"^Server:.*?^\s+Tag:\s*(\S+)", output, re.MULTILINE | re.DOTALL)
    return match.group(1) if match else None


def node_ready(output):
    return re.search(r"^\s*nodeReady:\s*true\s*$", output, re.MULTILINE) is not None


def learners(output):
    return any(line.split()[-1] == "true" for line in output.splitlines()[1:] if line.split())


class Talos:
    def __init__(self, talosconfig, endpoint):
        self.base = ["talosctl", "--talosconfig", talosconfig, "--endpoints", endpoint]

    def run(self, node, *args, check=True, timeout=120):
        try:
            result = subprocess.run([*self.base, "--nodes", node, *args],
                                    capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            if check:
                raise UpgradeError(f"talosctl {' '.join(args)} on {node} timed out")
            return None
        if check and result.returncode != 0:
            raise UpgradeError(f"talosctl {' '.join(args)} on {node} failed: {result.stderr.strip()}")
        return result.stdout if result.returncode == 0 else None

    def talos_version(self, node, check=True):
        output = self.run(node, "version", check=check)
        return output and server_tag(output)

    def schematic(self, node, check=True):
        output = self.run(node, "get", "extensions", "-o", "json", check=check)
        if output is None:
            return None
        decoder = json.JSONDecoder()
        pending = output.strip()
        try:
            # NOTE: The CLI prints one JSON document per extension, with no enclosing array.
            while pending:
                resource, end = decoder.raw_decode(pending)
                metadata = resource["spec"]["metadata"]
                if metadata["name"] == "schematic":
                    version = metadata["version"]
                    if not re.fullmatch(r"[a-f0-9]{64}", version):
                        raise ValueError("invalid schematic ID")
                    return version
                pending = pending[end:].lstrip()
        except (KeyError, TypeError, ValueError) as exc:
            if check:
                raise UpgradeError(f"invalid extension status on {node}: {exc}") from exc
            return None
        return ""

    def boot_id(self, node, check=True):
        output = self.run(node, "read", "/proc/sys/kernel/random/boot_id", check=check)
        value = output.strip() if output is not None else ""
        if re.fullmatch(r"[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}", value):
            return value
        if check:
            raise UpgradeError(f"could not read the boot ID on {node}")
        return None

    def etcd_healthy(self, nodes):
        # Every expected controller must be a voting member and answer etcd status.
        members = self.run(nodes[0], "etcd", "members", check=False)
        status = self.run(",".join(nodes), "etcd", "status", check=False)
        return (members is not None and status is not None and not learners(members)
                and parse_member_ips(members) == sorted(nodes))

    def ready(self, node, target, nodes):
        output = self.run(node, "get", "nodestatus", "-o", "yaml", check=False)
        return (self.talos_version(node, check=False) == target and output is not None
                and node_ready(output) and self.etcd_healthy(nodes))


def wait(description, condition):
    deadline = time.monotonic() + NODE_TIMEOUT
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(POLL_SECONDS)
    raise UpgradeError(f"timed out waiting for {description}")


def matches_install(talos, node, target, schematic_id):
    version = talos.talos_version(node)
    if not version:
        raise UpgradeError(f"could not read the Talos version on {node}")
    return version == target and talos.schematic(node) == schematic_id


def upgrade_talos(talos, nodes, target, image, schematic_id=None):
    pending = None if schematic_id is None else {
        node for node in nodes if not matches_install(talos, node, target, schematic_id)
    }
    for node in nodes:
        ready = f"{node} to run Talos {target}, be Ready and keep etcd healthy"
        needs_upgrade = talos.talos_version(node) != target if pending is None else node in pending
        if not needs_upgrade:
            # NOTE: A first apply can install the schematic before CNI and Kubernetes node readiness.
            if pending:
                wait(ready, lambda: talos.ready(node, target, nodes))
            print(f"{node}: already at Talos {target}", flush=True)
            continue
        if not talos.etcd_healthy(nodes):
            raise UpgradeError(f"etcd is not healthy with members {nodes}; not upgrading {node}")
        boot_id = talos.boot_id(node) if schematic_id is not None else None
        print(f"{node}: upgrading Talos to {target} with {image}", flush=True)
        # NOTE: The forward can drop during the reboot.
        talos.run(node, "upgrade", "--image", image, "--wait=false", timeout=300)
        wait(ready,
             lambda: (schematic_id is None or (
                 (current_boot := talos.boot_id(node, check=False)) is not None
                 and current_boot != boot_id and talos.schematic(node, check=False) == schematic_id
             )) and talos.ready(node, target, nodes))
        print(f"{node}: Talos {target} Ready", flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("kind", choices=("talos",))
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--nodes", required=True, help="comma-separated controller private IPs")
    parser.add_argument("--target", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--schematic-id")
    args = parser.parse_args(argv)
    nodes = [node for node in args.nodes.split(",") if node]
    if not nodes:
        parser.error("--nodes is empty")
    fd, path = tempfile.mkstemp(suffix=".yaml")
    try:
        with os.fdopen(fd, "w") as handle:
            # JSON is valid YAML, and the client certs are already base64 as talosconfig expects.
            json.dump({"context": "upgrade", "contexts": {"upgrade": {
                "endpoints": [args.endpoint], "ca": os.environ["TALOS_CA"],
                "crt": os.environ["TALOS_CRT"], "key": os.environ["TALOS_KEY"]}}}, handle)
        talos = Talos(path, args.endpoint)
        upgrade_talos(talos, nodes, args.target, args.image, args.schematic_id)
    except FileNotFoundError:
        sys.exit("version_upgrade: talosctl not found on PATH")
    except (KeyError, UpgradeError) as exc:
        sys.exit(f"version_upgrade: {exc}")
    finally:
        os.unlink(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
