#!/usr/bin/env python3
"""Evaluate module HCL and validate rendered Talos configs without AWS access."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Contracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="talos-contract-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        (self.path / "vars.tf").write_text((ROOT / "vars.tf").read_text())

    def evaluate(self, expression, overrides=()):
        command = ["tofu", "console", "-var=cluster_name=contract", "-var=vpc_id=vpc-test",
                   "-var=machine_secrets=null", "-var=client_configuration=null",
                   "-var=talos_api_allowed_cidrs=[]", "-var=kube_api_allowed_cidrs=[]", *overrides]
        output = subprocess.check_output(command, input="jsonencode(" + expression + ")\n",
                                         text=True, cwd=self.path)
        return json.loads(json.loads(output))

    def backup_fixture(self):
        backup = (ROOT / "backup.tf").read_text()
        locals_block = backup[backup.index("locals {"):]
        policy = backup.split('resource "aws_s3_bucket_policy" "etcd_backup" {', 1)[1]
        policy = policy[policy.index("jsonencode("):policy.index('\n}\n')].strip()
        source = locals_block + "\nlocals { policy = " + policy + " }\n"
        for reference, value in {
            "aws_s3_bucket.etcd_backup.arn": "arn:aws:s3:::contract",
            "aws_s3_bucket.etcd_backup.id": "contract",
            "aws_kms_key.etcd_backup.arn": "arn:aws:kms:us-east-2:123456789012:key/contract",
            "aws_iam_access_key.etcd_backup.id": "test",
            "aws_iam_access_key.etcd_backup.secret": "test",
            "data.aws_region.current.region": "us-east-2",
        }.items():
            source = source.replace(reference, json.dumps(value))
        (self.path / "main.tf").write_text(source)

    def test_backup_runtime(self):
        self.backup_fixture()
        manifests = self.evaluate("local.backup_manifests")
        self.assertNotIn("ConfigMap", [m["kind"] for m in manifests])
        cron = next(m for m in manifests if m["kind"] == "CronJob")
        pod = cron["spec"]["jobTemplate"]["spec"]["template"]["spec"]
        self.assertNotIn("initContainers", pod)
        container = pod["containers"][0]
        self.assertRegex(container["image"], r"^ghcr.io/siderolabs/talos-backup:v.*@sha256:[a-f0-9]{64}$")
        self.assertEqual(container["command"], ["/talos-backup"])
        env = {item["name"]: item["value"] for item in container["env"]}
        self.assertEqual(env["S3_PREFIX"], "etcd/contract")
        self.assertEqual(env["DISABLE_ENCRYPTION"], "true")
        self.assertEqual(cron["spec"]["schedule"], "0 * * * *")
        changed = self.evaluate("local.backup_manifests", ["-var=etcd_backup_schedule=15 */6 * * *"])
        self.assertEqual(next(m for m in changed if m["kind"] == "CronJob")["spec"]["schedule"], "15 */6 * * *")
        self.assertEqual(self.evaluate("var.etcd_backup_retention_days"), 7)
        self.assertEqual(self.evaluate("var.etcd_backup_retention_days", ["-var=etcd_backup_retention_days=30"]), 30)

    def test_bucket_encryption_policy(self):
        self.backup_fixture()
        statements = json.loads(self.evaluate("local.policy"))["Statement"]
        algorithm = "s3:x-amz-server-side-encryption"
        key = algorithm + "-aws-kms-key-id"
        expected_key = "arn:aws:kms:us-east-2:123456789012:key/contract"

        def denied(headers):
            def matches(operator, name, expected):
                if operator == "Null":
                    return (name not in headers) == (expected == "true")
                if operator == "StringEquals":
                    return headers.get(name) == expected
                if operator == "StringNotEquals":
                    return headers.get(name) != expected
                raise AssertionError(operator)
            return any(all(matches(op, name, expected) for op, conditions in s["Condition"].items()
                           for name, expected in conditions.items())
                       for s in statements if s["Action"] == "s3:PutObject")

        for headers, expected in [({}, False), ({algorithm: "aws:kms", key: expected_key}, False),
                                  ({algorithm: "AES256"}, True), ({algorithm: "aws:kms"}, True),
                                  ({algorithm: "aws:kms", key: "other-key"}, True), ({key: "other-key"}, True)]:
            with self.subTest(headers=headers):
                self.assertEqual(denied(headers), expected)

    def test_worker_configuration_validates(self):
        main = (ROOT / "main.tf").read_text()
        patches = main.split("  cilium_config_patches =", 1)[1].split("\n}", 1)[0]
        worker = main.split('data "talos_machine_configuration" "worker" {', 1)[1].split("\n}", 1)[0]
        worker_expression = worker.split("config_patches", 1)[1].split("=", 1)[1].strip()
        (self.path / "main.tf").write_text("locals {\n cilium_patches = " + patches + "\nworker_patches = " + worker_expression + "\n}")
        controller_patches = self.evaluate("local.cilium_patches", ["-var=cilium_enabled=true"])
        worker_patches = self.evaluate("local.worker_patches", ["-var=cilium_enabled=true"])
        cp = self.path / "controller-patch.yaml"
        cp.write_text("\n---\n".join(controller_patches))
        output = self.path / "generated"
        command = ["talosctl", "gen", "config", "contract", "https://127.0.0.1:6443", "--output-dir", str(output),
                   "--config-patch-control-plane", "@" + str(cp)]
        if worker_patches:
            patch = self.path / "worker-patch.yaml"
            patch.write_text("\n---\n".join(worker_patches))
            command += ["--config-patch-worker", "@" + str(patch)]
        subprocess.run(command, check=True, capture_output=True)
        subprocess.run(["talosctl", "validate", "--config", str(output / "worker.yaml"), "--mode", "cloud"], check=True)
        self.assertIn("enabled: false", (output / "controlplane.yaml").read_text())

    def test_architecture_guards(self):
        for item in self.path.iterdir():
            item.unlink()
        shutil.copyfile(ROOT / "architecture.tf", self.path / "main.tf")
        variables = (ROOT / "vars.tf").read_text()
        names = {"control_plane_instance_types", "control_plane_instance_type", "worker_instance_type", "worker_instance_types"}
        blocks = re.split(r'(?=^variable ")', variables, flags=re.M)
        selected = [b for b in blocks if any(b.startswith('variable "' + name + '"') for name in names)]
        (self.path / "vars.tf").write_text("\n".join(selected))
        (self.path / "providers.tf").write_text('terraform {\n required_providers {\n aws = { source = "hashicorp/aws", version = "6.73.0" }\n }\n}\n')
        shutil.copyfile(Path(__file__).with_name("architecture.tftest.hcl"), self.path / "architecture.tftest.hcl")
        subprocess.run(["tofu", "init", "-backend=false", "-input=false"], cwd=self.path, check=True, capture_output=True)
        subprocess.run(["tofu", "test"], cwd=self.path, check=True)


if __name__ == "__main__":
    unittest.main()
