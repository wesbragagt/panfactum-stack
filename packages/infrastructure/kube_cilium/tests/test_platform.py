#!/usr/bin/env python3
"""Evaluate actual platform expressions without AWS/Kubernetes access or state writes."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PlatformTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="cilium-platform-")
        cls.path = Path(cls.directory.name)
        (cls.path / "vars.tf").write_text((ROOT / "vars.tf").read_text())
        platform = (ROOT / "platform.tf").read_text().split("# Keep EKS state addresses", 1)[0]
        source = (ROOT / "main.tf").read_text()
        counts = {}
        for name, heading in {
            "eks_lookups": 'data "aws_eks_cluster" "cluster"',
            "iam_modules": 'module "aws_permissions"',
            "iam_annotations": 'resource "kubernetes_annotations" "service_account"',
            "managed_namespaces": 'module "namespace"',
        }.items():
            body = source.split(heading + " {", 1)[1]
            counts[name] = re.search(r"\n\s*count\s*=\s*([^\n]+)", body).group(1)
        platform += "\nlocals {\n" + "\n".join(f"test_{name} = {expr}" for name, expr in counts.items()) + "\n}\n"
        (cls.path / "platform.tf").write_text(platform)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def evaluate(self, **variables):
        args = [shutil.which("tofu") or "tofu", "-chdir=" + str(self.path), "console", "-no-color"]
        (self.path / "case.tfvars.json").write_text(json.dumps(variables))
        args += ["-var-file=case.tfvars.json"]
        expression = "jsonencode({values=local.platform_values, eni=local.eni_enabled, eks=local.test_eks_lookups, iam=local.test_iam_modules, annotations=local.test_iam_annotations, namespaces=local.test_managed_namespaces, tolerations=local.platform_tolerations})"
        result = subprocess.run(args, input=expression + "\n", text=True, capture_output=True, check=True)
        self.assertTrue(result.stdout.strip(), result.stderr)
        return json.loads(json.loads(result.stdout.strip()))

    def test_default_eks_network_values_and_resources_are_preserved(self):
        value = self.evaluate()
        self.assertEqual(value["values"], {
            "eni": {"enabled": True, "awsEnablePrefixDelegation": True, "awsReleaseExcessIPs": True},
            "ipam": {"mode": "eni"}, "enableIPv4Masquerade": False,
            "egressMasqueradeInterfaces": "eth0", "routingMode": "native",
        })
        self.assertEqual([value[k] for k in ("eks", "iam", "annotations", "namespaces")], [1, 1, 1, 1])
        self.assertEqual(value["tolerations"], [])

    def test_talos_cluster_pool_uses_no_eks_or_eni_iam_and_existing_namespace(self):
        value = self.evaluate(cluster_type="talos", namespace_create=False, namespace="kube-system")
        self.assertEqual([value[k] for k in ("eks", "iam", "annotations", "namespaces")], [0, 0, 0, 0])
        self.assertEqual(value["values"]["ipam"], {"mode": "cluster-pool", "operator": {"clusterPoolIPv4PodCIDRList": ["10.244.0.0/16"]}})
        self.assertTrue(value["values"]["enableIPv4Masquerade"])
        self.assertEqual(value["values"]["routingMode"], "tunnel")
        self.assertFalse(value["values"]["cgroup"]["autoMount"]["enabled"])
        self.assertNotIn("SYS_MODULE", value["values"]["securityContext"]["capabilities"]["ciliumAgent"])
        self.assertEqual(value["tolerations"][0]["key"], "node-role.kubernetes.io/control-plane")

    def test_talos_kubernetes_ipam_has_no_cluster_pool_configuration(self):
        value = self.evaluate(cluster_type="talos", ipam_mode="kubernetes")
        self.assertEqual(value["values"]["ipam"], {"mode": "kubernetes"})
        self.assertFalse(value["eni"])
        self.assertEqual(value["eks"], 0)

    def test_invalid_talos_eni_does_not_instantiate_iam_before_precondition(self):
        value = self.evaluate(cluster_type="talos", ipam_mode="eni")
        self.assertEqual([value[k] for k in ("eks", "iam", "annotations")], [0, 0, 0])


if __name__ == "__main__":
    unittest.main()
