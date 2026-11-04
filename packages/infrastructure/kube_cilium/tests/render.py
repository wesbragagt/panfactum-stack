#!/usr/bin/env python3
"""Render Talos platform values against Cilium 1.20.4; requires Helm and PyYAML."""
import json
import subprocess
import yaml
from test_platform import PlatformTests

PlatformTests.setUpClass()
try:
    case = PlatformTests()
    values = case.evaluate(cluster_type="talos", namespace_create=False)["values"]
    values.update(kubeProxyReplacement=True, k8sServiceHost="localhost", k8sServicePort=7445, operator={"replicas": 1})
    path = case.path / "values.json"
    path.write_text(json.dumps(values))
    rendered = subprocess.check_output([
        "helm", "template", "cilium", "cilium", "--repo", "https://helm.cilium.io",
        "--version", "1.20.4", "--namespace", "kube-system", "--kube-version", "1.37.1", "-f", str(path),
    ], text=True)
    objects = [obj for obj in yaml.safe_load_all(rendered) if obj]
    config = next(obj for obj in objects if obj["kind"] == "ConfigMap" and obj["metadata"]["name"] == "cilium-config")["data"]
    assert config["ipam"] == "cluster-pool"
    assert str(config["enable-ipv4-masquerade"]).lower() == "true"
    assert config["routing-mode"] == "tunnel"
    daemon = next(obj for obj in objects if obj["kind"] == "DaemonSet" and obj["metadata"]["name"] == "cilium")
    pod = daemon["spec"]["template"]["spec"]
    agent = next(container for container in pod["containers"] if container["name"] == "cilium-agent")
    env = {item["name"]: item.get("value") for item in agent["env"]}
    assert env["KUBERNETES_SERVICE_HOST"] == "localhost"
    assert env["KUBERNETES_SERVICE_PORT"] == "7445"
    assert "SYS_MODULE" not in agent["securityContext"]["capabilities"]["add"]
    assert not any(container["name"] == "mount-cgroup" for container in pod["initContainers"])
    operator = next(obj for obj in objects if obj["kind"] == "Deployment" and obj["metadata"]["name"] == "cilium-operator")
    assert operator["spec"]["replicas"] == 1
    print("Talos platform Helm render passed: cluster-pool/tunnel/masquerade, KubePrism, capabilities/cgroups, one operator")
finally:
    PlatformTests.tearDownClass()
