#!/usr/bin/env python3
"""Render the pinned Redis chart for explicit single-node and unchanged HA policies.

Usage: python tests/check_single_node_chart.py /path/to/redis-20.5.0.tgz
No cluster access or real credentials are used.
"""
import json
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import yaml

chart = Path(sys.argv[1]).resolve()
assert chart.name == "redis-20.5.0.tgz"
# Exercise the actual lifecycle gate expression, including unsafe combinations.
source = (Path(__file__).resolve().parents[1]/"main.tf").read_text()
condition = re.search(r"precondition \{\s*condition\s*= ([^\n]+)", source).group(1)
expressions = [condition.replace("var.allow_single_node", str(flag).lower()).replace("var.replica_count", str(count)) for flag, count in [(False, 3), (False, 1), (True, 1), (True, 3)]]
with tempfile.TemporaryDirectory(prefix="redis-single-gate-") as folder:
    gate = subprocess.run(["tofu", "console", "-no-color"], cwd=folder, input="jsonencode(["+", ".join(expressions)+"])\n", capture_output=True, text=True, check=True)
assert json.loads(json.loads(gate.stdout)) == [True, False, True, False]
print("PASS: module gate permits HA/default or explicit singleton, rejects implicit singleton and mismatched opt-in")
for single in [False, True]:
    replicas, quorum = (1, 1) if single else (3, 2)
    retention = "Retain" if single else "Delete"
    values = {
        "fullnameOverride": "redis-proof", "global": {"security": {"allowInsecureImages": True}}, "auth": {"password": "nonsecret-test-placeholder"},
        "image": {"repository": "bitnamilegacy/redis"},
        "rbac": {"create": True}, "serviceAccount": {"create": True, "automountServiceAccountToken": True},
        "replica": {"replicaCount": replicas, "automountServiceAccountToken": True, "persistence": {"enabled": True, "size": "1Gi"}},
        "sentinel": {"enabled": True, "quorum": quorum,
                     "image": {"repository": "bitnamilegacy/redis-sentinel"},
                     "service": {"createMaster": True},
                     "persistentVolumeClaimRetentionPolicy": {"enabled": True, "whenScaled": retention, "whenDeleted": retention}},
    }
    with tempfile.TemporaryDirectory(prefix="redis-single-render-") as folder:
        path = Path(folder)/"values.json"; path.write_text(json.dumps(values))
        result = subprocess.run(["helm", "template", "redis-proof", str(chart), "--kube-version", "1.37.1", "--namespace", "test", "-f", str(path)], capture_output=True, text=True)
        if result.returncode: raise RuntimeError(result.stderr)
    objects = [o for o in yaml.safe_load_all(result.stdout) if o]
    stateful = [o for o in objects if o["kind"] == "StatefulSet"]
    assert len(stateful) == 1
    assert stateful[0]["spec"]["replicas"] == replicas
    assert stateful[0]["spec"]["persistentVolumeClaimRetentionPolicy"] == {"whenScaled": retention, "whenDeleted": retention}
    configs = [o for o in objects if o["kind"] == "ConfigMap"]
    lines = [line for o in configs for line in o.get("data", {}).get("sentinel.conf", "").splitlines() if line.startswith("sentinel monitor ")]
    assert len(lines) == 1 and lines[0].split()[-1] == str(quorum), lines
    print(f"PASS: Redis replicas={replicas}, Sentinel quorum={quorum}, PVC policy={retention}")
