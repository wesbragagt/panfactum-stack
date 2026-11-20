import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/etcd_members.py"
spec = importlib.util.spec_from_file_location("etcd_members", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

SAMPLE = """NODE        ID                 HOSTNAME        PEER URLS                  CLIENT URLS                LEARNER
10.0.1.10   3d5b1c0a6e7f8a9b   ip-10-0-1-10    https://10.0.1.10:2380     https://10.0.1.10:2379     false
10.0.1.10   7a8b9c0d1e2f3a4b   ip-10-0-2-10    https://10.0.2.10:2380     https://10.0.2.10:2379     false
"""


class EtcdMembersTest(unittest.TestCase):
    def test_parses_peer_ips_only(self):
        self.assertEqual(module.parse_member_ips(SAMPLE), ["10.0.1.10", "10.0.2.10"])

    def test_empty_output_has_no_members(self):
        self.assertEqual(module.parse_member_ips(""), [])

    def test_missing_talosctl_fails_and_removes_the_temp_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run([sys.executable, str(SCRIPT)], input=json.dumps({"endpoint": "127.0.0.1", "node": "10.0.1.10", "ca": "x", "crt": "x", "key": "x"}),
                                    env={"PATH": "", "TMPDIR": tmp}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("talosctl", result.stderr)
            self.assertEqual(list(Path(tmp).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
