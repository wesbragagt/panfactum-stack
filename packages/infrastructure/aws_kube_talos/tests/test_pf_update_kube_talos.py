import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/pf-update-kube-talos"


class UpdateKubeTalosTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        base = Path(self.temporary.name)
        self.root = base / "primary"
        self.root.mkdir()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "-c", "user.name=Test", "-c",
                        "user.email=test@example.invalid", "commit", "-q", "--allow-empty", "-m", "initial"], check=True)
        self.linked = base / "linked"
        subprocess.run(["git", "-C", str(self.root), "worktree", "add", "-q", "-b", "linked",
                        str(self.linked)], check=True)
        self.kube_dir = self.root / ".kube"
        self.kube_dir.mkdir()
        self.scripts = base / "module"
        self.scripts.mkdir()
        shutil.copy(SCRIPT, self.scripts / "pf-update-kube-talos")
        self.log = base / "calls"
        recorder = '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["TEST_LOG"], "a") as log:
    log.write(json.dumps([os.path.basename(sys.argv[0]), sys.argv[1:], os.getcwd(),
                          os.environ.get("KUBE_DIR"), os.environ.get("KUBECONFIG")]) + "\\n")
if sys.argv[1:] == ["build"]:
    sys.exit(int(os.environ.get("TEST_BUILD_FAILURE", "0")))
'''
        (self.scripts / "pf-bootstrap-talos").write_text(recorder)
        bin_dir = base / "bin"
        bin_dir.mkdir()
        (bin_dir / "pf-update-kube").write_text(recorder)
        (bin_dir / "pf-update-kube").chmod(0o755)
        metadata = bin_dir / "pf-get-repo-variables"
        metadata.write_text('#!/usr/bin/env python3\nimport json, os\nprint(json.dumps({"kube_dir": os.path.join(os.getcwd(), ".kube")}))\n')
        metadata.chmod(0o755)
        self.env = {**os.environ, "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
                    "TEST_LOG": str(self.log), "KUBE_DIR": str(base / "wrong"),
                    "KUBECONFIG": str(base / "wrong-config")}

    def run_update(self, cwd, *args):
        result = subprocess.run(["python3", str(self.scripts / "pf-update-kube-talos"), *args], cwd=cwd,
                                env=self.env, text=True, capture_output=True)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, calls

    def test_plain_run_calls_only_merge(self):
        (self.kube_dir / "cluster_info.talos").write_text("{}")
        result, calls = self.run_update(self.linked)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[:2] for call in calls], [["pf-bootstrap-talos", ["merge"]]])
        self.assertEqual(calls[0][2:], [str(self.root), str(self.kube_dir), str(self.kube_dir / "config")])

    def test_build_calls_build_then_merge(self):
        for flag in ("-b", "--build"):
            self.log.unlink(missing_ok=True)
            result, calls = self.run_update(self.linked, flag)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([call[:2] for call in calls],
                             [["pf-bootstrap-talos", ["build"]], ["pf-bootstrap-talos", ["merge"]]])
            for call in calls:
                self.assertEqual(call[2:], [str(self.root), str(self.kube_dir), str(self.kube_dir / "config")])

    def test_build_failure_skips_merge(self):
        self.env["TEST_BUILD_FAILURE"] = "7"
        result, calls = self.run_update(self.root, "--build")
        self.assertEqual(result.returncode, 7)
        self.assertEqual([call[1] for call in calls], [["build"]])

    def test_missing_cluster_info_asks_for_build(self):
        result, calls = self.run_update(self.root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("run pf-update-kube-talos --build", result.stderr)
        self.assertEqual(calls, [])

    def test_pf_update_kube_is_never_called(self):
        (self.kube_dir / "cluster_info.talos").write_text("{}")
        for args in ((), ("--build",), ("--talosconfig", "ctx")):
            self.log.unlink(missing_ok=True)
            _result, calls = self.run_update(self.root, *args)
            self.assertNotIn("pf-update-kube", [call[0] for call in calls])

    def test_talosconfig_delegates_without_updating_kubeconfig(self):
        for args in (("--talosconfig",), ("--talosconfig", "my-cluster")):
            self.log.unlink(missing_ok=True)
            result, calls = self.run_update(self.linked, *args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0][0:2], ["pf-bootstrap-talos", ["talosconfig", *args[1:]]])
            self.assertEqual(calls[0][2:], [str(self.root), str(self.kube_dir), str(self.kube_dir / "config")])

    def test_help_does_not_update_config(self):
        result, calls = self.run_update(self.root, "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--talosconfig", result.stdout)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
