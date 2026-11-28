import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from types import SimpleNamespace

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/cluster_access.py"
spec = importlib.util.spec_from_file_location("cluster_access", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ClusterAccessTest(unittest.TestCase):
    def test_help_works_outside_the_repository_without_tools(self):
        with tempfile.TemporaryDirectory() as empty:
            result = subprocess.run([sys.executable, str(SCRIPT), "--help"], cwd=empty, env={"PATH": ""},
                                    capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--exec-credential", result.stdout)

    def test_cluster_is_required(self):
        env = {key: value for key, value in os.environ.items() if key != "TF_VAR_cluster_name"}
        result = subprocess.run([sys.executable, str(SCRIPT), "--exec-credential"], env=env, capture_output=True,
                                text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("inputs.cluster_name", result.stderr)

    def test_terragrunt_output_preserves_only_supported_transport_overrides(self):
        args = SimpleNamespace(profile=None, region=None, module=Path("/module"))
        for inherited, expected in (("vpn", None), ("bootstrap_public", "bootstrap_public"), ("auto", "auto")):
            with self.subTest(inherited=inherited), tempfile.TemporaryDirectory() as directory, \
                    unittest.mock.patch.dict(os.environ, {"PF_TALOS_TRANSPORT": inherited}), \
                    unittest.mock.patch.object(module, "command", return_value=b"output") as command:
                self.assertEqual(module.terragrunt_output(args, Path(directory), "cluster_name"), b"output")
                self.assertEqual(command.call_args.kwargs["env"].get("PF_TALOS_TRANSPORT"), expected)

    def test_direct_credential_cache_distinguishes_recreated_cluster_ca(self):
        def exec_info(ca):
            return {"KUBERNETES_EXEC_INFO": json.dumps({"spec": {
                "cluster": {"certificate-authority-data": ca},
            }})}

        credentials = [
            {"clientCertificateData": name, "clientKeyData": "key",
             "expirationTimestamp": "2100-01-01T00:00:00Z"}
            for name in ("old", "new")
        ]
        with tempfile.TemporaryDirectory() as directory, \
                unittest.mock.patch.object(module, "read_source_kubeconfig"), \
                unittest.mock.patch.object(module, "credential_status", side_effect=credentials) as fetch:
            args = SimpleNamespace(module=Path("/module"), profile="test", region="us-east-2",
                                   state_dir=Path(directory), source_kubeconfig=None)
            for ca, expected in (("ca-old", 0), ("ca-new", 1), ("ca-new", 1)):
                with unittest.mock.patch.dict(os.environ, exec_info(ca)):
                    self.assertEqual(module.vpn_credential(args), credentials[expected])
            self.assertEqual(fetch.call_count, 2)


if __name__ == "__main__":
    unittest.main()
