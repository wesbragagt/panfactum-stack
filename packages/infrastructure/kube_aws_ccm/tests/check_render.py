"""Check a Helm-rendered CCM manifest (PyYAML required).

Usage: python check_render.py rendered.yaml
Render using the actual planned static values and a placeholder IRSA role.
"""
import argparse
from pathlib import Path

import yaml


def check(path, image_version="v1.37.0", talos_bootstrap=False):
    docs = [doc for doc in yaml.safe_load_all(Path(path).read_text()) if doc]
    ds = next(doc for doc in docs if doc["kind"] == "DaemonSet")
    spec = ds["spec"]["template"]["spec"]
    container = spec["containers"][0]
    assert container["image"] == f"registry.k8s.io/provider-aws/cloud-controller-manager:{image_version}"
    selectors = [arg for arg in container["args"] if arg.startswith("--controllers=")]
    # cloud-node-lifecycle deletes Nodes whose instances terminated (Spot reclaims).
    assert selectors == ["--controllers=cloud-node,cloud-node-lifecycle"]
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
    if talos_bootstrap:
        assert any(t["key"] == "controller" and t["effect"] == "NoSchedule"
                   for t in spec["tolerations"])
        assert any(v["name"] == "aws-web-identity" and
                   v["projected"]["sources"][0]["serviceAccountToken"]["audience"] == "sts.amazonaws.com"
                   for v in spec["volumes"])
        assert any(m["name"] == "aws-web-identity" and
                   m["mountPath"] == "/var/run/secrets/eks.amazonaws.com/serviceaccount" and
                   m["readOnly"] for m in container["volumeMounts"])
        assert any(e["name"] == "AWS_WEB_IDENTITY_TOKEN_FILE" and
                   e["value"] == "/var/run/secrets/eks.amazonaws.com/serviceaccount/token"
                   for e in container["env"])
    assert container["resources"]["requests"] == {"cpu": "50m", "memory": "128Mi"}
    sa = next(doc for doc in docs if doc["kind"] == "ServiceAccount")
    assert sa["metadata"]["name"] == spec["serviceAccountName"]
    assert sa["metadata"]["annotations"]["eks.amazonaws.com/role-arn"].startswith("arn:aws:iam::")
    role = next(doc for doc in docs if doc["kind"] == "ClusterRole")
    for rule in role["rules"]:
        assert "*" not in rule["verbs"]
        if "delete" in rule["verbs"]:
            assert rule["resources"] == ["nodes"]
        assert not set(rule["resources"]) & {"services", "services/status", "persistentvolumes", "serviceaccounts"}
    assert not any(doc["kind"] in {"Service", "Namespace"} for doc in docs)
    print("CCM chart contract checks passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("path")
    parser.add_argument("--image-version", default="v1.37.0")
    parser.add_argument("--talos-bootstrap", action="store_true")
    args = parser.parse_args()
    check(args.path, args.image_version, args.talos_bootstrap)
