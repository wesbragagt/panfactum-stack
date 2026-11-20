#!/usr/bin/env python3
"""OpenTofu external data source: print the private IPs of the current etcd members.

Reads {"endpoint", "node", "ca", "crt", "key"} on stdin, builds a talosconfig and runs `talosctl etcd members`, so talosctl
must be on PATH and the Talos API reachable. Any failure exits non-zero, which fails the plan.
"""

import json
import os
import re
import subprocess
import sys
import tempfile


def parse_member_ips(output):
    # Peer URLs use port 2380; client URLs (2379) are ignored.
    return sorted(set(re.findall(r"https?://(\d{1,3}(?:\.\d{1,3}){3}):2380", output)))


def main():
    query = json.load(sys.stdin)
    fd, path = tempfile.mkstemp(suffix=".yaml")
    try:
        with os.fdopen(fd, "w") as handle:
            # JSON is valid YAML, and the client certs are already base64 as talosconfig expects.
            json.dump({"context": "guard", "contexts": {"guard": {
                "endpoints": [query["endpoint"]], "ca": query["ca"], "crt": query["crt"], "key": query["key"]}}}, handle)
        result = subprocess.run(["talosctl", "--talosconfig", path, "-n", query["node"], "etcd", "members"],
                                capture_output=True, text=True)
    except FileNotFoundError:
        sys.exit("etcd_members: talosctl not found on PATH")
    finally:
        os.unlink(path)
    if result.returncode != 0:
        sys.exit(f"etcd_members: talosctl etcd members failed (is the operator tunnel up?): {result.stderr.strip()}")
    print(json.dumps({"member_ips": ",".join(parse_member_ips(result.stdout))}))


if __name__ == "__main__":
    main()
