import importlib.util
import json
from pathlib import Path
import re
import sys
import unittest
from unittest.mock import Mock, patch

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
SCHEMATIC = "a" * 64


class ParseTest(unittest.TestCase):
    def test_server_tag_ignores_client(self):
        self.assertEqual(module.server_tag(VERSION), "v1.14.6")

    def test_node_ready(self):
        self.assertTrue(module.node_ready("spec:\n    nodeReady: true\n"))
        self.assertFalse(module.node_ready("spec:\n    nodeReady: false\n"))

    def test_learners(self):
        self.assertFalse(module.learners(MEMBERS))
        self.assertTrue(module.learners(MEMBERS.replace("2379  false\n", "2379  true\n", 1)))

    def test_reads_schematic_from_consecutive_extension_documents(self):
        output = "\n".join(json.dumps({"spec": {"metadata": {"name": name, "version": version}}})
                           for name, version in (("ecr-credential-provider", "1.0.0"), ("schematic", SCHEMATIC)))
        talos = module.Talos("config", "endpoint")
        talos.run = Mock(side_effect=[output, "", None])
        self.assertEqual(talos.schematic("10.0.1.10"), SCHEMATIC)
        self.assertEqual(talos.schematic("10.0.1.10"), "")
        self.assertIsNone(talos.schematic("10.0.1.10", check=False))

    def test_invalid_extension_report_is_not_treated_as_a_different_schematic(self):
        talos = module.Talos("config", "endpoint")
        talos.run = Mock(return_value="invalid")
        with self.assertRaisesRegex(module.UpgradeError, "extension"):
            talos.schematic("10.0.1.10")
        self.assertIsNone(talos.schematic("10.0.1.10", check=False))


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

    def test_same_version_installs_new_schematic_and_waits_for_reboot(self):
        node = "10.0.1.10"
        talos = Mock()
        talos.talos_version.return_value = "v1.14.6"
        talos.schematic.side_effect = ["", "b" * 64, SCHEMATIC]
        talos.boot_id.side_effect = ["boot-before", "boot-before", None, "boot-after", "boot-after"]
        talos.etcd_healthy.return_value = True
        talos.ready.return_value = True
        with patch.object(module.time, "sleep"):
            module.upgrade_talos(talos, [node], "v1.14.6", "img", SCHEMATIC)
        talos.run.assert_called_once_with(node, "upgrade", "--image", "img", "--wait=false", timeout=300)
        self.assertEqual(talos.boot_id.call_count, 5)
        self.assertEqual(talos.schematic.call_count, 3)

    def test_same_version_and_schematic_are_already_done_before_cni(self):
        node = "10.0.1.10"
        talos = Mock()
        talos.talos_version.return_value = "v1.14.6"
        talos.schematic.return_value = SCHEMATIC
        talos.ready.return_value = False
        module.upgrade_talos(talos, [node], "v1.14.6", "img", SCHEMATIC)
        talos.run.assert_not_called()
        talos.ready.assert_not_called()


class OrderingTest(unittest.TestCase):
    # tftest cannot read depends_on, so check the source.
    def test_machine_apply_waits_for_the_serial_talos_upgrade(self):
        main = (MODULE / "main.tf").read_text()
        machine = re.search(r'resource "talos_machine" "control_plane" \{.*?\n\}', main, re.DOTALL).group(0)
        self.assertIn("terraform_data.talos_upgrade", machine)
        self.assertRegex(machine, r"ignore_changes\s*=\s*\[image\]")


if __name__ == "__main__":
    unittest.main()
