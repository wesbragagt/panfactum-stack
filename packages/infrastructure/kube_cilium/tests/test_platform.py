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
        platform = platform.replace("local.private_subnets_by_name", "var.mock_private_subnets")
        platform += '''
variable "mock_cluster_name" {
  type    = string
  default = "example-cluster"
}
variable "mock_private_subnets" {
  type    = map(string)
  default = { PRIVATE_B = "subnet-b", PRIVATE_A = "subnet-a" }
}
locals {
  cluster_name = var.cluster != null ? var.cluster.name : var.mock_cluster_name
}
'''
        counts = {}
        counts["envoy"] = source.split("      envoy = {", 1)[1].split("enabled =", 1)[1].split("\n", 1)[0].strip()
        counts["l7_proxy"] = source.split("      l7Proxy =", 1)[1].split("\n", 1)[0].strip()
        counts["namespace_labels"] = source.split('module "namespace" {', 1)[1].split("extra_labels =", 1)[1].split("\n", 1)[0].strip()
        for name, heading in {
            "eks_lookups": 'data "aws_eks_cluster" "cluster"',
            "iam_modules": 'module "aws_permissions"',
            "iam_annotations": 'resource "kubernetes_annotations" "service_account"',
            "managed_namespaces": 'module "namespace"',
        }.items():
            body = source.split(heading + " {", 1)[1]
            counts[name] = re.search(r"\n\s*count\s*=\s*([^\n]+)", body).group(1)
        actions = source.split('data "aws_iam_policy_document" "cilium" {', 1)[1].split("actions =", 1)[1].split("resources =", 1)[0].strip()
        platform += "\nlocals { test_iam_actions = " + actions + " }\n"
        operator = source.split("        extraEnv =", 1)[1].split("        prometheus =", 1)[0]
        operator = "extraEnv =" + operator
        operator = operator.replace("module.aws_permissions[0].role_arn", '"arn:aws:iam::123456789012:role/cilium"').replace("data.aws_region.region.region", '"us-east-2"')
        platform += "\nlocals { test_operator = merge({" + operator + "}, local.operator_web_identity) }\n"
        counts["operator_replicas"] = re.search(r"\breplicas = ([^\n]+)", source).group(1)
        platform += "\nlocals {\n" + "\n".join(f"test_{name} = {expr}" for name, expr in counts.items()) + "\n}\n"
        (cls.path / "platform.tf").write_text(platform)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def evaluate(self, **variables):
        args = [shutil.which("tofu") or "tofu", "-chdir=" + str(self.path), "console", "-no-color"]
        (self.path / "case.tfvars.json").write_text(json.dumps(variables))
        args += ["-var-file=case.tfvars.json"]
        expression = "jsonencode({envoy=local.test_envoy, l7_proxy=local.test_l7_proxy, namespace_labels=local.test_namespace_labels, iam_actions=local.test_iam_actions, operator=local.test_operator, values=local.platform_values, eni=local.eni_enabled, eks=local.test_eks_lookups, iam=local.test_iam_modules, annotations=local.test_iam_annotations, namespaces=local.test_managed_namespaces, tolerations=local.platform_tolerations, identity=local.operator_web_identity, replicas=local.test_operator_replicas, use_cache=local.pull_through_cache_enabled, scoped_eni=local.scoped_eni})"
        result = subprocess.run(args, input=expression + "\n", text=True, capture_output=True, check=True)
        self.assertTrue(result.stdout.strip(), result.stderr)
        return json.loads(json.loads(result.stdout.strip()))

    def test_optional_proxy_and_namespace_settings(self):
        eks = self.evaluate()
        self.assertFalse(eks["envoy"])
        self.assertTrue(eks["l7_proxy"])
        self.assertEqual(eks["namespace_labels"], {})
        self.assertTrue(self.evaluate(cluster_type="talos")["envoy"])
        value = self.evaluate(cluster_type="talos", envoy_enabled=False,
                              l7_proxy_enabled=False,
                              namespace_labels={"pod-security.kubernetes.io/enforce": "privileged"})
        self.assertFalse(value["envoy"])
        self.assertFalse(value["l7_proxy"])
        self.assertEqual(value["namespace_labels"], {"pod-security.kubernetes.io/enforce": "privileged"})

    def test_default_eks_network_values_and_resources_are_preserved(self):
        value = self.evaluate()
        self.assertEqual(value["values"], {
            "eni": {"enabled": True, "awsEnablePrefixDelegation": True, "awsReleaseExcessIPs": True},
            "ipam": {"mode": "eni"}, "enableIPv4Masquerade": False,
            "egressMasqueradeInterfaces": "eth0", "routingMode": "native",
        })
        self.assertEqual([value[k] for k in ("eks", "iam", "annotations", "namespaces")], [1, 1, 1, 1])
        self.assertEqual(value["tolerations"], [])
        self.assertEqual(self.evaluate(cluster={"type": "aws_eks", "name": "example-eks"}), value)
        self.assertEqual(self.evaluate(cluster_type="eks"), value)

    def test_standard_talos_eni_defaults_follow_cluster_and_sla(self):
        for name, sla_target, replicas in (("example-north", 1, 1), ("example-south", 2, 2)):
            with self.subTest(name=name):
                value = self.evaluate(cluster={"type": "talos", "name": name}, sla_target=sla_target)
                self.assertEqual([value[k] for k in ("eks", "iam", "annotations", "namespaces")], [0, 1, 1, 1])
                eni = value["values"]["eni"]
                self.assertEqual(eni["eniTags"], {"homelab-cluster": name})
                self.assertEqual(eni["gcTags"], eni["eniTags"])
                self.assertEqual(eni["nodeSpec"], {"firstInterfaceIndex": 1, "subnetIDs": ["subnet-a", "subnet-b"]})
                self.assertEqual(value["namespace_labels"], {"pod-security.kubernetes.io/enforce": "privileged"})
                self.assertEqual(value["replicas"], replicas)
                self.assertFalse(value["use_cache"])
                self.assertTrue(value["scoped_eni"])
                self.assertEqual([t["key"] for t in value["tolerations"]], [
                    "node-role.kubernetes.io/control-plane",
                    "node.cloudprovider.kubernetes.io/uninitialized",
                    "ebs.csi.aws.com/agent-not-ready",
                ])

    def test_talos_object_respects_explicit_ipam_mode(self):
        value = self.evaluate(cluster={"type": "talos", "name": "example-cluster"}, ipam_mode="cluster-pool")
        self.assertEqual(value, self.evaluate(cluster_type="talos"))

    def test_route_table_permission_is_talos_eni_only(self):
        baseline = set(self.evaluate()["iam_actions"])
        self.assertNotIn("ec2:DescribeRouteTables", baseline)
        self.assertEqual(set(self.evaluate(cluster_type="talos")["iam_actions"]), baseline)
        actual = set(self.evaluate(cluster_type="talos", ipam_mode="eni")["iam_actions"])
        self.assertEqual(actual - baseline, {"ec2:DescribeRouteTables"})
        self.assertEqual(baseline - actual, set())

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

    def test_talos_routing_mode_override_sets_native_routing_cidr(self):
        value = self.evaluate(cluster_type="talos", routing_mode="native", ipv4_native_routing_cidr="10.0.0.0/16")
        self.assertEqual(value["values"]["routingMode"], "native")
        self.assertEqual(value["values"]["ipv4NativeRoutingCIDR"], "10.0.0.0/16")

    def test_routing_cidr_is_omitted_when_unset(self):
        value = self.evaluate(cluster_type="talos")
        self.assertNotIn("ipv4NativeRoutingCIDR", value["values"])

    def test_talos_eni_uses_private_allocation_and_projected_identity(self):
        value = self.evaluate(cluster_type="talos", ipam_mode="eni",
                              eni_cluster_tag="test-cluster", eni_first_interface_index=1,
                              eni_subnet_ids_filter=["subnet-private"],
                              oidc_provider_arn="arn:aws:iam::123456789012:oidc-provider/issuer.example",
                              oidc_issuer_url="https://issuer.example")
        self.assertEqual([value[k] for k in ("eks", "iam", "annotations")], [0, 1, 1])
        self.assertEqual(value["values"]["routingMode"], "native")
        self.assertFalse(value["values"]["enableIPv4Masquerade"])
        eni = value["values"]["eni"]
        self.assertEqual(eni["nodeSpec"], {"subnetIDs": ["subnet-private"], "firstInterfaceIndex": 1})
        self.assertEqual(eni["eniTags"], eni["gcTags"])
        token = value["identity"]["extraVolumes"][0]["projected"]["sources"][0]["serviceAccountToken"]
        self.assertEqual(token["audience"], "sts.amazonaws.com")
        self.assertTrue(value["identity"]["extraVolumeMounts"][0]["readOnly"])

    def test_projected_identity_is_omitted_for_eks_and_talos_overlay(self):
        self.assertEqual(self.evaluate()["identity"], {})
        self.assertEqual(self.evaluate(cluster_type="talos")["identity"], {})

    def test_web_identity_fields_are_omitted_outside_talos_eni(self):
        for variables in ({}, {"cluster_type": "talos"}):
            value = self.evaluate(**variables)
            self.assertNotIn("extraVolumes", value["operator"])
            self.assertNotIn("extraVolumeMounts", value["operator"])
            self.assertFalse(any(env["name"] == "AWS_WEB_IDENTITY_TOKEN_FILE" for env in value["operator"]["extraEnv"]))
        eks = self.evaluate()["operator"]["extraEnv"]
        self.assertEqual(eks, [{"name": "AWS_ROLE_ARN", "value": "arn:aws:iam::123456789012:role/cilium"}, {"name": "AWS_REGION", "value": "us-east-2"}])

    def test_talos_eni_network_and_credentials(self):
        value = self.evaluate(cluster_type="talos", ipam_mode="eni",
                              eni_cluster_tag="homelab-talos-canary",
                              eni_subnet_ids_filter=["subnet-a", "subnet-b", "subnet-c"],
                              eni_first_interface_index=1,
                              oidc_provider_arn="arn:aws:iam::123456789012:oidc-provider/canary.example",
                              oidc_issuer_url="https://canary.example")
        self.assertTrue(value["values"]["eni"]["enabled"])
        self.assertEqual(value["values"]["routingMode"], "native")
        self.assertEqual(value["values"]["ipam"], {"mode": "eni"})
        self.assertEqual(value["values"]["eni"]["nodeSpec"]["subnetIDs"], ["subnet-a", "subnet-b", "subnet-c"])
        self.assertEqual(value["values"]["eni"]["nodeSpec"], {"firstInterfaceIndex": 1, "subnetIDs": ["subnet-a", "subnet-b", "subnet-c"]})
        self.assertEqual(value["values"]["eni"]["eniTags"], value["values"]["eni"]["gcTags"])
        self.assertEqual(value["operator"]["extraVolumes"][0]["projected"]["sources"][0]["serviceAccountToken"]["audience"], "sts.amazonaws.com")
        self.assertEqual([value[k] for k in ("eks", "iam", "annotations")], [0, 1, 1])
        self.assertIn("SYS_ADMIN", value["values"]["securityContext"]["capabilities"]["ciliumAgent"])
        self.assertEqual(value["tolerations"][0]["key"], "node-role.kubernetes.io/control-plane")

    def test_invalid_talos_eni_does_not_instantiate_iam_or_eks(self):
        value = self.evaluate(cluster_type="talos", ipam_mode="eni")
        self.assertEqual([value[k] for k in ("eks", "iam", "annotations")], [0, 0, 0])

    def test_local_uses_cluster_pool_without_eks_eni_or_talos_host_settings(self):
        value = self.evaluate(cluster_type="local", k8s_service_host="kind-1-control-plane", k8s_service_port=6443)
        self.assertEqual([value[k] for k in ("eks", "iam", "annotations", "namespaces")], [0, 0, 0, 1])
        self.assertEqual(value["values"]["ipam"], {"mode": "cluster-pool", "operator": {"clusterPoolIPv4PodCIDRList": ["10.244.0.0/16"]}})
        self.assertEqual(value["values"]["routingMode"], "tunnel")
        self.assertNotIn("cgroup", value["values"])
        self.assertNotIn("securityContext", value["values"])
        self.assertFalse(any(env["name"].startswith("AWS_") for env in value["operator"]["extraEnv"]))

    def test_local_eni_never_creates_iam(self):
        value = self.evaluate(cluster_type="local", ipam_mode="eni")
        self.assertEqual([value[k] for k in ("eks", "iam", "annotations")], [0, 0, 0])


if __name__ == "__main__":
    unittest.main()
