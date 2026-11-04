#!/usr/bin/env python3
"""Evaluate the module's actual OIDC and resource-gating expressions offline."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class OIDCTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="panfactum-oidc-")
        cls.path = Path(cls.temp.name)
        (cls.path / "vars.tf").write_text((ROOT / "vars.tf").read_text())
        source = (ROOT / "main.tf").read_text()
        body = source.split("locals {", 1)[1].split("\n}", 1)[0]
        replacements = {
            "data.aws_eks_cluster.cluster[0].identity[0].oidc[0].issuer": "local.mock_eks_issuer",
            "data.aws_caller_identity.main.account_id": "local.mock_account",
            "data.aws_subnet.cluster_subnet_info": "local.mock_subnets",
            "data.pf_metadata.metadata.kube_cluster_name": "local.mock_cluster",
        }
        for old, new in replacements.items():
            body = body.replace(old, new)
        gates = {}
        for name, heading in {
            "eks": 'data "aws_eks_cluster" "cluster"',
            "subnets": 'data "aws_subnets" "cluster_subnets"',
            "ip_policy": 'resource "aws_iam_policy" "ip_blocks"',
            "ip_attachment": 'resource "aws_iam_policy_attachment" "ip_blocks"',
        }.items():
            gates[name] = re.search(r"\n\s*count\s*=\s*([^\n]+)", source.split(heading + " {", 1)[1]).group(1)
        checks = re.findall(r"precondition\s*\{\s*condition\s*=\s*([^\n]+)", source)
        checks = [c.replace("data.aws_caller_identity.main.account_id", "local.mock_account") for c in checks]
        body += '\n mock_account="111122223333"\n mock_cluster="test"\n mock_eks_issuer="https://oidc.eks.us-east-2.amazonaws.com/id/EXAMPLE"\n mock_subnets=[]\n'
        body += "\n".join(f"test_{k}={v}" for k, v in gates.items())
        body += "\n checks=[" + ",".join(checks) + "]\n"
        (cls.path / "main.tf").write_text("locals {" + body + "\n}\n")

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def evaluate(self, **variables):
        values = dict(service_account="agent", service_account_namespace="system", iam_policy_json="{}")
        values.update(variables)
        (self.path / "case.tfvars.json").write_text(json.dumps(values))
        expr = "jsonencode({issuer=local.kube_oidc_provider,principal=local.oidc_principal,custom=local.custom_oidc_requested,checks=local.checks,eks=local.test_eks,subnets=local.test_subnets,ip_policy=local.test_ip_policy,ip_attachment=local.test_ip_attachment})"
        result = subprocess.run([shutil.which("tofu") or "tofu", "-chdir="+str(self.path), "console", "-no-color", "-var-file=case.tfvars.json"], input=expr+"\n", text=True, capture_output=True, check=True)
        return json.loads(json.loads(result.stdout.strip()))

    def test_default_eks_lookup_and_ip_resources_remain_enabled(self):
        result = self.evaluate()
        self.assertEqual([result[k] for k in ("eks", "subnets", "ip_policy", "ip_attachment")], [1, 1, 1, 1])
        self.assertEqual(result["principal"], "arn:aws:iam::111122223333:oidc-provider/oidc.eks.us-east-2.amazonaws.com/id/EXAMPLE")
        self.assertTrue(all(result["checks"]))

    def test_custom_oidc_no_eks_and_explicit_ip_opt_out(self):
        result = self.evaluate(oidc_provider_arn="arn:aws:iam::111122223333:oidc-provider/issuer.example/cluster", oidc_issuer_url="https://issuer.example/cluster/", cluster_subnet_ids=[], ip_restrictions_enabled=False)
        self.assertEqual([result[k] for k in ("eks", "subnets", "ip_policy", "ip_attachment")], [0, 0, 0, 0])
        self.assertEqual(result["issuer"], "issuer.example/cluster")
        self.assertTrue(all(result["checks"]))

    def test_partial_custom_input_rejected_without_eks_lookup(self):
        result = self.evaluate(oidc_provider_arn="arn:aws:iam::111122223333:oidc-provider/issuer.example")
        self.assertEqual(result["eks"], 0)
        self.assertFalse(result["checks"][0])

    def test_issuer_mismatch_rejected(self):
        result = self.evaluate(oidc_provider_arn="arn:aws:iam::111122223333:oidc-provider/wrong.example", oidc_issuer_url="https://issuer.example")
        self.assertFalse(result["checks"][1])

    def test_foreign_provider_account_rejected(self):
        result = self.evaluate(oidc_provider_arn="arn:aws:iam::999900001111:oidc-provider/issuer.example", oidc_issuer_url="https://issuer.example")
        self.assertFalse(result["checks"][1])

    def test_explicit_subnets_skip_discovery_but_retain_ip_policies(self):
        result = self.evaluate(cluster_subnet_ids=["subnet-explicit"])
        self.assertEqual([result[k] for k in ("subnets", "ip_policy", "ip_attachment")], [0, 1, 1])


if __name__ == "__main__":
    unittest.main()
