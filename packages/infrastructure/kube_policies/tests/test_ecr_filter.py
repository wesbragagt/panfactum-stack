#!/usr/bin/env python3
"""Run with Python + PyYAML, tofu (or TERRAFORM), and Kyverno CLI 1.17.1.

KYVERNO=/path/to/kyverno python3 tests/test_ecr_filter.py
Renders the actual HCL locals without AWS providers or cluster access.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import yaml

MODULE = Path(__file__).resolve().parents[1]
KYVERNO = os.environ.get("KYVERNO", "kyverno")
TF = os.environ.get("TERRAFORM", "tofu")
CACHE = "111122223333.dkr.ecr.us-east-2.amazonaws.com/"


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def main():
    assert "1.17.1" in run(KYVERNO, "version"), "Use the deployed engine version"
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        source = (MODULE / "pull_through_image_cache.tf").read_text()
        source = source.replace("${data.aws_caller_identity.current.account_id}", "111122223333").replace("${data.aws_region.current.region}", "us-east-2").replace("var.pull_through_cache_enabled", "true")
        source += '''\nlocals { match_any_pod_create = { any = [{ resources = { kinds = ["Pod"] } }] } }
output "policy" { value = { apiVersion = "kyverno.io/v1", kind = "ClusterPolicy", metadata = { name = "ecr-filter-test", annotations = { "pod-policies.kyverno.io/autogen-controllers" = "none" } }, spec = { background = false, rules = local.rule_use_pull_through_image_cache } } }
'''
        (root / "main.tf").write_text(source)
        run(TF, f"-chdir={root}", "init", "-backend=false", "-no-color")
        run(TF, f"-chdir={root}", "apply", "-auto-approve", "-no-color")
        policy = json.loads(run(TF, f"-chdir={root}", "output", "-json", "policy"))
        policy_path = root / "policy.yaml"
        policy_path.write_text(yaml.safe_dump(policy))
        cases = []
        for host, prefix in [("ghcr.io", "github"), ("cr.l5d.io", "github"), ("docker.io", "docker-hub"), ("index.docker.io", "docker-hub"), ("quay.io", "quay"), ("registry.k8s.io", "kubernetes"), ("public.ecr.aws", "ecr-public")]:
            for suffix in ["app:v1", "app@sha256:" + "a" * 64]:
                cases.append((host + "/" + suffix, CACHE + prefix + "/" + suffix))
        for image in [CACHE + "github/app:v1", "999988887777.dkr.ecr.eu-west-1.amazonaws.com/app:v1", "999988887777.dkr.ecr.cn-north-1.amazonaws.com.cn/app:v1", "999988887777.dkr.ecr-fips.us-gov-west-1.amazonaws.com/app:v1", "example.com/path.dkr.ecr./app:v1", "999988887777.dkr.ecr.us-east-2.amazonaws.com.evil/app:v1"]:
            cases.append((image, image))
        cases += [("ghcr.io/path.dkr.ecr./app:v1", CACHE + "github/path.dkr.ecr./app:v1"), ("nginx:latest", CACHE + "docker-hub/nginx:latest")]
        for optout in [False, True]:
            pod = {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "ecr-test", "namespace": "default", "labels": {"panfactum.com/pull-through-cache-enabled": "false"} if optout else {}}, "spec": {key: [{"name": f"c{i}", "image": image} for i, (image, _) in enumerate(cases)] for key in ["containers", "initContainers"]}}
            for pass_number in range(2):
                resource = root / "pod.yaml"
                resource.write_text(yaml.safe_dump(pod))
                out = root / f"out-{optout}-{pass_number}"
                out.mkdir()
                result = run(KYVERNO, "apply", str(policy_path), "-r", str(resource), "-o", str(out))
                assert "error: 0" in result and "fail: 0" in result, result
                files = list(out.glob("*.yaml"))
                mutated = next(yaml.safe_load_all(files[0].read_text())) if files else pod
                for key in ["containers", "initContainers"]:
                    actual = {c["name"]: c["image"] for c in mutated["spec"][key]}
                    expected_images = {f"c{i}": original if optout else expected for i, (original, expected) in enumerate(cases)}
                    assert actual == expected_images, (actual, expected_images)
                pod = mutated
        # Missing initContainers must still satisfy the original empty-list precondition.
        pod["metadata"]["labels"] = {}
        pod["spec"].pop("initContainers")
        (root / "pod.yaml").write_text(yaml.safe_dump(pod))
        result = run(KYVERNO, "apply", str(policy_path), "-r", str(root / "pod.yaml"))
        assert "error: 0" in result, result
        print(f"PASS: {len(cases)} image cases, normal/init, opt-out, two-pass idempotence, missing init; real HCL + Kyverno 1.17.1")


if __name__ == "__main__":
    main()
