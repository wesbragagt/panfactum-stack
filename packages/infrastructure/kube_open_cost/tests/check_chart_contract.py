#!/usr/bin/env python3
"""Exercise the pinned upstream chart's Prometheus/monitor override contract.

This checks chart behavior, not a Terraform plan or live compatibility. Run with
Helm and PyYAML available. No Kubernetes context or AWS credentials are used.
"""
import json
from pathlib import Path
import subprocess
import tempfile
import yaml

VERSION = "2.5.12"


def render(chart, folder, values):
    path = folder / "values.json"
    path.write_text(json.dumps(values))
    result = subprocess.run([
        "helm", "template", "open-cost", str(chart), "--namespace", "open-cost",
        "--kube-version", "1.37.1", "--values", str(path),
    ], capture_output=True, text=True, check=True)
    return [d for d in yaml.safe_load_all(result.stdout) if d]


def container_env(objects):
    deployment = next(d for d in objects if d["kind"] == "Deployment")
    container = next(c for c in deployment["spec"]["template"]["spec"]["containers"]
                     if c["image"].startswith("ghcr.io/opencost/opencost:"))
    return container, {v["name"]: v.get("value") for v in container["env"]}


with tempfile.TemporaryDirectory(prefix="opencost-chart-contract-") as directory:
    folder = Path(directory)
    subprocess.run([
        "helm", "pull", "opencost", "--repo", "https://opencost.github.io/opencost-helm-chart",
        "--version", VERSION, "--destination", str(folder),
    ], check=True)
    chart = folder / f"opencost-{VERSION}.tgz"
    default = {"opencost": {
        "ui": {"enabled": False},
        "metrics": {"serviceMonitor": {"enabled": True}},
        "prometheus": {"external": {"enabled": False, "url": None},
                       "internal": {"enabled": True, "namespaceName": "monitoring",
                                     "serviceName": "thanos-query-frontend", "port": 9090}},
    }}
    objects = render(chart, folder, default)
    assert any(d["kind"] == "ServiceMonitor" for d in objects)
    _, env = container_env(objects)
    assert env["PROMETHEUS_SERVER_ENDPOINT"] == "http://thanos-query-frontend.monitoring.svc.cluster.local:9090"

    minimal = {"opencost": {
        "ui": {"enabled": False},
        "metrics": {"serviceMonitor": {"enabled": False}},
        "prometheus": {"internal": {"enabled": False},
                       "external": {"enabled": True, "url": "http://prometheus.monitoring.svc:9090"}},
        "exporter": {"resources": {"requests": {"memory": "200Mi"}}},
    }}
    objects = render(chart, folder, minimal)
    assert not any(d["kind"] in ["ServiceMonitor", "PodMonitor"] for d in objects)
    container, env = container_env(objects)
    assert env["PROMETHEUS_SERVER_ENDPOINT"] == "http://prometheus.monitoring.svc:9090"
    assert container["resources"]["requests"]["memory"] == "200Mi"
    assert container["image"].startswith("ghcr.io/opencost/opencost:1.119.2@sha256:")
    print("PASS: pinned chart default endpoint/monitor and explicit minimal endpoint/no-monitor contracts")
