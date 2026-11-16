#!/usr/bin/env python3
"""Render actual module ENI and operator expressions for both platforms."""
import json
import subprocess
import yaml
from test_platform import PlatformTests

PlatformTests.setUpClass()
try:
    case = PlatformTests()
    for platform in ("talos", "eks"):
        result = case.evaluate(cluster_type=platform, ipam_mode="eni",
                               eni_cluster_tag="homelab-talos-canary",
                               eni_subnet_ids_filter=["subnet-a", "subnet-b", "subnet-c"],
                               eni_first_interface_index=1)
        values = result["values"]
        values["operator"] = result["operator"]
        path = case.path / "eni.json"
        path.write_text(json.dumps(values))
        rendered = subprocess.check_output([
            "helm", "template", "cilium", "cilium", "--repo", "https://helm.cilium.io",
            "--version", "1.20.4", "--namespace", "kube-system", "-f", str(path),
        ], text=True)
        objects = [o for o in yaml.safe_load_all(rendered) if o]
        config = next(o["data"] for o in objects if o["kind"] == "ConfigMap" and o["metadata"]["name"] == "cilium-config")
        assert config["ipam"] == "eni"
        assert config["routing-mode"] == "native"
        assert config["eni-first-interface-index"] == "1"
        assert config["eni-subnet-ids"] == "subnet-a,subnet-b,subnet-c"
        assert "subnet-ids-filter" not in config
        if platform == "talos":
            assert json.loads(config["eni-tags"]) == {"homelab-cluster": "homelab-talos-canary"}
            assert json.loads(config["eni-gc-tags"]) == json.loads(config["eni-tags"])
        pod = next(o["spec"]["template"]["spec"] for o in objects if o["kind"] == "Deployment" and o["metadata"]["name"] == "cilium-operator")
        env = {e["name"]: e.get("value") for e in pod["containers"][0]["env"]}
        volumes = [v for v in pod.get("volumes", []) if v["name"] == "aws-web-identity"]
        if platform == "talos":
            assert env["AWS_WEB_IDENTITY_TOKEN_FILE"] == "/var/run/secrets/eks.amazonaws.com/serviceaccount/token"
            assert env["AWS_REGION"] == "us-east-2"
            assert env["AWS_ROLE_ARN"].endswith(":role/cilium")
            assert volumes[0]["projected"]["sources"][0]["serviceAccountToken"] == {"audience": "sts.amazonaws.com", "expirationSeconds": 86400, "path": "token"}
            assert any(m["mountPath"] == "/var/run/secrets/eks.amazonaws.com/serviceaccount" and m["readOnly"] for m in pod["containers"][0]["volumeMounts"])
            assert "homelab-talos-canary" in rendered
        else:
            assert not volumes
            assert "AWS_WEB_IDENTITY_TOKEN_FILE" not in env
        print(platform + " ENI render passed")
finally:
    PlatformTests.tearDownClass()
