#!/usr/bin/env python3
"""Evaluate the CCM module's Helm values without provider or cluster access."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ROLE_ARN = "arn:aws:iam::123456789012:role/ccm"
ROLE_ANNOTATION = {"eks.amazonaws.com/role-arn": ROLE_ARN}


def values_expression(source):
    resource = source.split('resource "helm_release" "ccm" {', 1)[1]
    values = resource.split("  values = ", 1)[1].split("\n  depends_on =", 1)[0]
    return values.replace("module.aws_permissions.role_arn", json.dumps(ROLE_ARN)).replace(
        "module.aws_permissions.service_account_annotations", json.dumps(ROLE_ANNOTATION)
    )


class CCMValuesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="ccm-values-")
        cls.path = Path(cls.directory.name)
        (cls.path / "vars.tf").write_text((ROOT / "vars.tf").read_text())
        values = values_expression((ROOT / "main.tf").read_text())
        (cls.path / "values.tf").write_text(
            'locals {\n  name = "aws-cloud-controller-manager"\n  values = '
            + values + "\n}\n"
        )

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def evaluate(self, **overrides):
        variables = {
            "region": "us-east-2",
            "cluster_name": "example",
            "availability_zone": "us-east-2b",
            "vpc_id": "vpc-example",
            "subnet_id": "subnet-example",
            **overrides,
        }
        (self.path / "case.tfvars.json").write_text(json.dumps(variables))
        result = subprocess.run(
            [shutil.which("tofu") or "tofu", "-chdir=" + str(self.path),
             "console", "-no-color", "-var-file=case.tfvars.json"],
            input="jsonencode([for value in local.values : yamldecode(value)])\n", text=True, capture_output=True, check=True,
        )
        return json.loads(json.loads(result.stdout.strip()))

    def test_talos_bootstrap_release_matches_existing_values(self):
        values, service_account = self.evaluate(talos_bootstrap_enabled=True, image_version="v1.36.1")
        self.assertEqual(values["image"], {
            "repository": "registry.k8s.io/provider-aws/cloud-controller-manager", "tag": "v1.36.1"
        })
        self.assertEqual(values["serviceAccountName"], "aws-cloud-controller-manager")
        self.assertEqual(values["clusterRoleRules"], [
            {"apiGroups": [""], "resources": ["events"], "verbs": ["create", "patch", "update"]},
            {"apiGroups": [""], "resources": ["nodes"], "verbs": ["get", "list", "watch", "patch", "update", "delete"]},
            {"apiGroups": [""], "resources": ["nodes/status"], "verbs": ["patch", "update"]},
            {"apiGroups": ["coordination.k8s.io"], "resources": ["leases"], "verbs": ["create", "get", "list", "watch", "patch", "update"]},
            {"apiGroups": ["authentication.k8s.io"], "resources": ["tokenreviews"], "verbs": ["create"]},
            {"apiGroups": ["authorization.k8s.io"], "resources": ["subjectaccessreviews"], "verbs": ["create"]},
        ])
        self.assertEqual(values["tolerations"], [
            {"key": "node.cloudprovider.kubernetes.io/uninitialized", "value": "true", "effect": "NoSchedule"},
            {"key": "node-role.kubernetes.io/master", "effect": "NoSchedule"},
            {"key": "node-role.kubernetes.io/control-plane", "effect": "NoSchedule"},
            {"key": "controller", "operator": "Equal", "value": "true", "effect": "NoSchedule"},
        ])
        env = {entry["name"]: entry["value"] for entry in values["env"]}
        self.assertEqual(env["AWS_ROLE_ARN"], ROLE_ARN)
        self.assertEqual(env["AWS_WEB_IDENTITY_TOKEN_FILE"], "/var/run/secrets/eks.amazonaws.com/serviceaccount/token")
        projected = next(volume["projected"] for volume in values["extraVolumes"] if volume["name"] == "aws-web-identity")
        self.assertEqual(projected["sources"], [{"serviceAccountToken": {
            "audience": "sts.amazonaws.com", "expirationSeconds": 86400, "path": "token"
        }}])
        self.assertIn({"name": "aws-web-identity", "mountPath": "/var/run/secrets/eks.amazonaws.com/serviceaccount", "readOnly": True}, values["extraVolumeMounts"])
        self.assertEqual(service_account, {"serviceAccount": {"annotations": ROLE_ANNOTATION}})

    def test_default_preserves_legacy_values(self):
        values, service_account = self.evaluate()
        self.assertEqual(values["image"]["tag"], "v1.37.0")
        self.assertIn("--controllers=cloud-node", values["args"])
        self.assertNotIn("delete", next(rule for rule in values["clusterRoleRules"] if rule["resources"] == ["nodes"])["verbs"])
        self.assertNotIn("tolerations", values)
        self.assertFalse(any(env["name"] in {"AWS_ROLE_ARN", "AWS_WEB_IDENTITY_TOKEN_FILE"} for env in values["env"]))
        self.assertEqual(values["extraVolumes"], [{"name": "cloud-config", "configMap": {"name": "aws-cloud-controller-manager"}}])
        self.assertEqual(values["extraVolumeMounts"], [{"name": "cloud-config", "mountPath": "/etc/aws", "readOnly": True}])
        self.assertEqual(service_account, {"serviceAccount": {"annotations": ROLE_ANNOTATION}})


if __name__ == "__main__":
    unittest.main()
