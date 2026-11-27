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
    return (
        values.replace("module.aws_permissions.role_arn", json.dumps(ROLE_ARN))
        .replace("module.aws_permissions.service_account_annotations", json.dumps(ROLE_ANNOTATION))
        .replace("data.aws_region.current.region", json.dumps("us-east-2"))
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
            "cluster": {
                "name": "example",
                "oidc_provider_arn": "arn:aws:iam::123456789012:oidc-provider/example",
                "oidc_issuer_url": "https://example.s3.us-east-2.amazonaws.com",
            },
            "controller_provider_ids": {"10.0.1.10": "aws:///us-east-2b/i-00000000000000001"},
            **overrides,
        }
        (self.path / "case.tfvars.json").write_text(json.dumps(variables))
        result = subprocess.run(
            [shutil.which("tofu") or "tofu", "-chdir=" + str(self.path),
             "console", "-no-color", "-var-file=case.tfvars.json"],
            input="jsonencode([for value in local.values : yamldecode(value)])\n", text=True, capture_output=True, check=True,
        )
        return json.loads(json.loads(result.stdout.strip()))

    def test_release_values(self):
        values, service_account = self.evaluate()
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
            {"key": "node.kubernetes.io/not-ready", "operator": "Exists", "effect": "NoSchedule"},
            {"key": "node-role.kubernetes.io/master", "effect": "NoSchedule"},
            {"key": "node-role.kubernetes.io/control-plane", "effect": "NoSchedule"},
            {"key": "controller", "operator": "Equal", "value": "true", "effect": "NoSchedule"},
        ])
        env = {entry["name"]: entry["value"] for entry in values["env"]}
        self.assertEqual(env["AWS_REGION"], "us-east-2")
        self.assertEqual(env["AWS_ROLE_ARN"], ROLE_ARN)
        self.assertEqual(env["AWS_WEB_IDENTITY_TOKEN_FILE"], "/var/run/secrets/eks.amazonaws.com/serviceaccount/token")
        projected = next(volume["projected"] for volume in values["extraVolumes"] if volume["name"] == "aws-web-identity")
        self.assertEqual(projected["sources"], [{"serviceAccountToken": {
            "audience": "sts.amazonaws.com", "expirationSeconds": 86400, "path": "token"
        }}])
        self.assertIn({"name": "aws-web-identity", "mountPath": "/var/run/secrets/eks.amazonaws.com/serviceaccount", "readOnly": True}, values["extraVolumeMounts"])
        self.assertEqual(service_account, {"serviceAccount": {"annotations": ROLE_ANNOTATION}})

    def test_uses_kubeprism_on_the_host_network(self):
        values, _ = self.evaluate()
        self.assertTrue(values["hostNetworking"])
        self.assertEqual(values["dnsPolicy"], "Default")
        env = {entry["name"]: entry["value"] for entry in values["env"]}
        self.assertEqual(env["KUBERNETES_SERVICE_HOST"], "127.0.0.1")
        self.assertEqual(env["KUBERNETES_SERVICE_PORT"], "7445")

    def test_image_version_override(self):
        values, _ = self.evaluate(image_version="v1.36.0")
        self.assertEqual(values["image"]["tag"], "v1.36.0")

    def test_accepts_the_full_aws_kube_talos_cluster_output(self):
        values, _ = self.evaluate(cluster={
            "type": "talos", "name": "example", "endpoint": "https://api.example.internal:6443",
            "oidc_provider_arn": "arn:aws:iam::123456789012:oidc-provider/example",
            "oidc_issuer_url": "https://example.s3.us-east-2.amazonaws.com",
        })
        self.assertEqual(values["serviceAccountName"], "aws-cloud-controller-manager")


if __name__ == "__main__":
    unittest.main()
