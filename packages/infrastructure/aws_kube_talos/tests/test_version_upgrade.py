import importlib.util
from pathlib import Path
import re
import sys
import unittest

MODULE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MODULE / "scripts"))
spec = importlib.util.spec_from_file_location("version_upgrade", MODULE / "scripts/version_upgrade.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

VERSION = """Client:
\tTag:         v1.15.0
Server:
\tNODE:        10.0.1.10
\tTag:         v1.14.6
"""
MEMBERS = """NODE        ID     HOSTNAME   PEER URLS               CLIENT URLS             LEARNER
10.0.1.10   a      cp-0       https://10.0.1.10:2380  https://10.0.1.10:2379  false
10.0.1.10   b      cp-1       https://10.0.2.10:2380  https://10.0.2.10:2379  false
"""


class ParseTest(unittest.TestCase):
    def test_server_tag_ignores_client(self):
        self.assertEqual(module.server_tag(VERSION), "v1.14.6")

    def test_node_ready(self):
        self.assertTrue(module.node_ready("spec:\n    nodeReady: true\n"))
        self.assertFalse(module.node_ready("spec:\n    nodeReady: false\n"))

    def test_learners(self):
        self.assertFalse(module.learners(MEMBERS))
        self.assertTrue(module.learners(MEMBERS.replace("2379  false\n", "2379  true\n", 1)))


class FakeTalos:
    def __init__(self, versions, healthy=True):
        self.versions = dict(versions)
        self.healthy = healthy
        self.upgraded = []

    def talos_version(self, node, check=True):
        return self.versions[node]

    def etcd_healthy(self, nodes):
        return self.healthy

    def run(self, node, *args, **kwargs):
        self.upgraded.append(node)
        self.versions[node] = "v1.15.0"

    def ready(self, node, target, nodes):
        return self.versions[node] == target


class UpgradeTalosTest(unittest.TestCase):
    def test_skips_nodes_at_target_and_upgrades_the_rest_in_order(self):
        talos = FakeTalos({"10.0.1.10": "v1.15.0", "10.0.2.10": "v1.14.6", "10.0.3.10": "v1.14.6"})
        module.upgrade_talos(talos, list(talos.versions), "v1.15.0", "img")
        self.assertEqual(talos.upgraded, ["10.0.2.10", "10.0.3.10"])

    def test_all_at_target_needs_no_etcd_check(self):
        talos = FakeTalos({"10.0.1.10": "v1.14.6"}, healthy=False)
        module.upgrade_talos(talos, ["10.0.1.10"], "v1.14.6", "img")
        self.assertEqual(talos.upgraded, [])

    def test_unhealthy_etcd_stops_before_upgrading(self):
        talos = FakeTalos({"10.0.1.10": "v1.14.6"}, healthy=False)
        with self.assertRaisesRegex(module.UpgradeError, "etcd"):
            module.upgrade_talos(talos, ["10.0.1.10"], "v1.15.0", "img")
        self.assertEqual(talos.upgraded, [])


class OrderingTest(unittest.TestCase):
    # tftest cannot read depends_on, so check the source.
    def test_machine_apply_waits_for_the_serial_talos_upgrade(self):
        main = (MODULE / "main.tf").read_text()
        machine = re.search(r'resource "talos_machine" "control_plane" \{.*?\n\}', main, re.DOTALL).group(0)
        self.assertIn("terraform_data.talos_upgrade", machine)
        self.assertRegex(machine, r"ignore_changes\s*=\s*\[image\]")


if __name__ == "__main__":
    unittest.main()
