#!/usr/bin/env python3
"""Check the exact Loki chart supports the module's opt-in SimpleScalable topology.

Usage: python tests/check_single_node_chart.py /path/to/loki-6.29.0.tgz
This renders only, using placeholder S3 names and no cluster credentials.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import yaml

chart = Path(sys.argv[1]).resolve()
assert chart.name == "loki-6.29.0.tgz"
for single in [False, True]:
    replicas = 1 if single else 3
    values = {
        "fullnameOverride": "loki", "deploymentMode": "SimpleScalable", "test": {"enabled": False},
        "loki": {"auth_enabled": False, "storage": {"type": "s3", "bucketNames": {"chunks": "placeholder-chunks", "ruler": "placeholder-ruler"}},
                 "structuredConfig": {"common": {"replication_factor": replicas},
                                      "schema_config": {"configs": [{"from": "2020-09-07", "index": {"period": "24h", "prefix": "index_"}, "object_store": "s3", "schema": "v13", "store": "tsdb"}]}}},
        "read": {"replicas": replicas},
        "write": {"replicas": replicas, "persistence": {"enabled": True, "size": "5Gi" if single else "2Gi", "storageClass": "ebs-standard-retained" if single else "ebs-standard", "enableStatefulSetAutoDeletePVC": not single}},
        "backend": {"replicas": replicas, "persistence": {"volumeClaimsEnabled": True, "size": "5Gi" if single else "2Gi", "storageClass": "ebs-standard-retained" if single else "ebs-standard", "enableStatefulSetAutoDeletePVC": not single}},
        "gateway": {"enabled": False}, "lokiCanary": {"enabled": False},
        "chunksCache": {"enabled": False}, "resultsCache": {"enabled": False},
    }
    with tempfile.TemporaryDirectory(prefix="loki-single-render-") as folder:
        path = Path(folder)/"values.json"; path.write_text(json.dumps(values))
        result = subprocess.run(["helm", "template", "loki", str(chart), "--kube-version", "1.37.1", "--namespace", "logging", "-f", str(path)], capture_output=True, text=True)
        if result.returncode: raise RuntimeError(result.stderr)
    objects = [o for o in yaml.safe_load_all(result.stdout) if o]
    workloads = {o["metadata"]["name"]: o for o in objects if o["kind"] in ["Deployment", "StatefulSet"]}
    for component in ["read", "write", "backend"]:
        assert workloads["loki-"+component]["spec"]["replicas"] == replicas
    for component in ["write", "backend"]:
        policy = workloads["loki-"+component]["spec"].get("persistentVolumeClaimRetentionPolicy", {})
        for claim in workloads["loki-"+component]["spec"]["volumeClaimTemplates"]:
            assert claim["spec"]["resources"]["requests"]["storage"] == ("5Gi" if single else "2Gi")
            assert claim["spec"]["storageClassName"] == ("ebs-standard-retained" if single else "ebs-standard")
        if single: assert all(policy.get(k, "Retain") == "Retain" for k in ["whenDeleted", "whenScaled"]), policy
        else: assert policy["whenDeleted"] == "Delete" and policy["whenScaled"] == "Delete", policy
    configs = [o for o in objects if o["kind"] in ["ConfigMap", "Secret"]]
    found = False
    import base64
    for obj in configs:
        for key, value in obj.get("data", {}).items():
            if "config" not in key: continue
            if obj["kind"] == "Secret": value = base64.b64decode(value).decode()
            try: config = yaml.safe_load(value)
            except yaml.YAMLError: continue
            if isinstance(config, dict) and "common" in config:
                assert config["common"]["replication_factor"] == replicas
                found = True
    assert found
    print(f"PASS: Loki SimpleScalable read/write/backend={replicas}, replication factor={replicas}, PVC auto-delete={not single}")
