"""Check a Helm-rendered CCM manifest (PyYAML required).

Usage: python check_render.py rendered.yaml
Render using the actual planned static values and a placeholder IRSA role.
"""
import sys
from pathlib import Path

import yaml


def check(path):
    docs = [doc for doc in yaml.safe_load_all(Path(path).read_text()) if doc]
    ds = next(doc for doc in docs if doc["kind"] == "DaemonSet")
    spec = ds["spec"]["template"]["spec"]
    container = spec["containers"][0]
    assert container["image"] == "registry.k8s.io/provider-aws/cloud-controller-manager:v1.37.0"
    selectors = [arg for arg in container["args"] if arg.startswith("--controllers=")]
    assert selectors == ["--controllers=cloud-node"]
    assert "--cloud-config=/etc/aws/cloud.conf" in container["args"]
    assert "--use-service-account-credentials=false" in container["args"]
    assert "--configure-cloud-routes=false" in container["args"]
    assert {"name": "AWS_EC2_METADATA_DISABLED", "value": "true"} in container["env"]
    assert any(m["mountPath"] == "/etc/aws" and m["name"] == "cloud-config"
               and m["readOnly"] for m in container["volumeMounts"])
    assert any(v["name"] == "cloud-config" and
               v["configMap"]["name"] == "aws-cloud-controller-manager" for v in spec["volumes"])
    assert spec["nodeSelector"] == {"node-role.kubernetes.io/control-plane": ""}
    assert any(t["key"] == "node.cloudprovider.kubernetes.io/uninitialized"
               and t["effect"] == "NoSchedule" for t in spec["tolerations"])
    assert container["resources"]["requests"] == {"cpu": "50m", "memory": "128Mi"}
    sa = next(doc for doc in docs if doc["kind"] == "ServiceAccount")
    assert sa["metadata"]["name"] == spec["serviceAccountName"]
    assert sa["metadata"]["annotations"]["eks.amazonaws.com/role-arn"].startswith("arn:aws:iam::")
    role = next(doc for doc in docs if doc["kind"] == "ClusterRole")
    for rule in role["rules"]:
        assert "*" not in rule["verbs"]
        assert "delete" not in rule["verbs"]
        assert not set(rule["resources"]) & {"services", "services/status", "persistentvolumes", "serviceaccounts"}
    assert not any(doc["kind"] in {"Service", "Namespace"} for doc in docs)
    print("CCM chart contract checks passed")


if __name__ == "__main__":
    check(sys.argv[1])
