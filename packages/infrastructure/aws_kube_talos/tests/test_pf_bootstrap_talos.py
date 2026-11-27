#!/usr/bin/env python3
"""Exercise pf-bootstrap-talos register and merge with fake terragrunt and kubectl.

Needs openssl for a throwaway CA certificate (present in the dev shell).
"""

import base64
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/pf-bootstrap-talos"

# The tests only write JSON, which kubectl also reads, so the fake prints the file.
FAKE_KUBECTL = '#!/bin/sh\nexec cat "$2"\n'
FAKE_TERRAGRUNT = '''#!/bin/sh
case "$3" in
  cluster_url) printf '%s' "${TEST_PRIVATE_URL:-https://api.example.internal:6443}" ;;
  control_plane_private_ips) printf '%s' '["10.0.0.5","10.0.1.5"]' ;;
  bootstrap_public_host) printf '%s' "${TEST_PUBLIC_HOST:-talos-1.elb.amazonaws.com}" ;;
  bootstrap_public_node) printf '%s' '10.0.1.5' ;;
  *) cat "$TEST_KUBECONFIG" ;;
esac
'''


class PreflightTests(unittest.TestCase):
    def test_preflight_checks_fixed_configuration_through_shared_helper(self):
        env = {key: value for key, value in os.environ.items() if key != "PF_TALOS_FIXED_SSM"}
        result = subprocess.run(["python3", str(SCRIPT), "preflight", "--cluster", "test"],
                                env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Set PF_TALOS_FIXED_SSM or pass --fixed-ssm FILE", result.stderr)
        self.assertEqual(result.stdout, "")


@unittest.skipUnless(shutil.which("openssl"), "openssl missing; run through the dev shell")
class PfBootstrapTalosTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.tmp = Path(temporary.name)
        self.root = (self.tmp / "repo").resolve()
        self.kube = self.root / ".kube"
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        for name in ("a", "b"):
            (self.root / f"env/{name}").mkdir(parents=True)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for name, body in (("kubectl", FAKE_KUBECTL), ("terragrunt", FAKE_TERRAGRUNT)):
            (bin_dir / name).write_text(body)
            (bin_dir / name).chmod(0o755)
        cert, key = self.tmp / "cert.pem", self.tmp / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key),
                        "-out", str(cert), "-days", "2", "-subj", "/CN=ca"], check=True, capture_output=True)
        self.ca = base64.b64encode(cert.read_bytes()).decode()
        source = self.tmp / "source.json"
        source.write_text(json.dumps({
            "current-context": "c", "contexts": [{"name": "c", "context": {"cluster": "c", "user": "u"}}],
            "clusters": [{"name": "c", "cluster": {"server": "https://10.0.0.5:6443",
                                                   "certificate-authority-data": self.ca}}],
            "users": [{"name": "u", "user": {}}]}))
        self.env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "TEST_KUBECONFIG": str(source),
                    "KUBE_DIR": str(self.kube)}
        self.env.pop("AWS_PROFILE", None)

    def run_cli(self, *argv):
        return subprocess.run(["python3", str(SCRIPT), *argv], cwd=self.root, env=self.env,
                              capture_output=True, text=True, timeout=60)

    def register(self, *options, name="a", env="a", kube_port="16443", talos_port="50000", profile="prof-a"):
        return self.run_cli("register", "--cluster", name, "--module", str(self.root / "env" / env),
                            "--region", "us-east-2", "--kube-port", kube_port,
                            "--talos-port", talos_port, "--profile", profile, *options)

    def config(self):
        return json.loads((self.kube / "config").read_text())

    def test_register_writes_both_files_and_merges(self):
        result = self.register()
        self.assertEqual(result.returncode, 0, result.stderr)
        committed = json.loads((self.kube / "config.talos.yaml").read_text())["clusters"]["a"]
        self.assertEqual(committed, {"region": "us-east-2", "kube_port": 16443, "talos_port": 50000,
                                     "module": "env/a", "ca_data": self.ca})
        self.assertEqual((self.kube / "config.talos.user.yaml").read_text(),
                         "clusters:\n  - name: a\n    aws_profile: prof-a\n")
        config = self.config()
        self.assertEqual(config["clusters"][0]["cluster"]["server"], "https://127.0.0.1:16443")
        self.assertEqual((self.kube / "config").stat().st_mode & 0o777, 0o600)
        # A second register keeps the user's existing profile entry.
        self.register(profile="other")
        self.assertEqual((self.kube / "config.talos.user.yaml").read_text(),
                         "clusters:\n  - name: a\n    aws_profile: prof-a\n")

    def user_file(self):
        return self.kube / "config.talos.user.yaml"

    def user_profiles(self):
        spec = importlib.util.spec_from_loader(
            "pf_bootstrap_talos", importlib.machinery.SourceFileLoader("pf_bootstrap_talos", str(SCRIPT)))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return {name: entry.get("aws_profile") for name, entry in module.read_user(self.user_file()).items()}

    def test_register_new_user_file_starts_with_clusters_key(self):
        self.assertEqual(self.register().returncode, 0)
        lines = [line for line in self.user_file().read_text().splitlines()
                 if line.strip() and not line.startswith("#")]
        self.assertEqual(lines[0], "clusters:")
        self.assertEqual(self.user_profiles(), {"a": "prof-a"})

    def test_register_appends_to_clusters_file_idempotently(self):
        self.kube.mkdir()
        self.user_file().write_text("# mine\nclusters:\n  - name: x\n    aws_profile: px\n")
        self.assertEqual(self.register().returncode, 0)
        expected = ("# mine\nclusters:\n  - name: x\n    aws_profile: px\n"
                    "  - name: a\n    aws_profile: prof-a\n")
        self.assertEqual(self.user_file().read_text(), expected)
        self.assertEqual(self.register(profile="other").returncode, 0)
        self.assertEqual(self.user_file().read_text(), expected)
        self.assertEqual(self.user_profiles(), {"x": "px", "a": "prof-a"})

    def test_register_keeps_bare_list_form(self):
        self.kube.mkdir()
        self.user_file().write_text("- name: x\n  aws_profile: px\n")
        self.assertEqual(self.user_profiles(), {"x": "px"})
        self.assertEqual(self.register().returncode, 0)
        self.assertEqual(self.user_file().read_text(),
                         "- name: x\n  aws_profile: px\n- name: a\n  aws_profile: prof-a\n")
        self.assertEqual(self.user_profiles(), {"x": "px", "a": "prof-a"})

    def test_default_kube_dir_is_repo_root_from_subdirectory(self):
        # Terragrunt hooks run from a nested cache directory without KUBE_DIR.
        del self.env["KUBE_DIR"]
        nested = self.root / "env/a/.terragrunt-cache/x"
        nested.mkdir(parents=True)
        result = subprocess.run(["python3", str(SCRIPT), "register", "--cluster", "a",
                                 "--module", str(self.root / "env/a"), "--region", "us-east-2",
                                 "--profile", "prof-a"], cwd=nested, env=self.env,
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.kube / "config.talos.yaml").is_file())
        self.assertFalse((nested / ".kube").exists())

    def test_default_kube_dir_is_shared_with_a_linked_checkout(self):
        del self.env["KUBE_DIR"]
        linked = self.tmp / "linked"
        subprocess.run(["git", "-C", str(self.root), "-c", "user.name=Test", "-c", "user.email=test@example.com",
                        "commit", "-q", "--allow-empty", "-m", "fixture"], check=True)
        subprocess.run(["git", "-C", str(self.root), "worktree", "add", "-q", "--detach", str(linked)], check=True)
        for checkout in (self.root, linked):
            scripts = checkout / "scripts"
            scripts.mkdir()
            for source in (SCRIPT, SCRIPT.with_name("cluster_access.py")):
                shutil.copy2(source, scripts / source.name)
        module = linked / "env/a"
        module.mkdir(parents=True)
        result = subprocess.run(["python3", str(linked / "scripts/pf-bootstrap-talos"), "register", "--cluster", "a",
                                 "--module", str(module), "--region", "us-east-2"], cwd=module,
                                env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((linked / ".kube").exists())
        args = self.config()["users"][0]["user"]["exec"]["args"]
        self.assertEqual(args[0], str(self.root / "scripts/cluster_access.py"))
        self.assertEqual(args[args.index("--module") + 1], str(self.root / "env/a"))
        before = (self.kube / "config").read_bytes()
        result = subprocess.run(["python3", str(self.root / "scripts/pf-bootstrap-talos"), "merge"], cwd=self.root,
                                env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.kube / "config").read_bytes(), before)

    def test_register_rejects_duplicate_ports(self):
        self.assertEqual(self.register().returncode, 0)
        for kube, talos in (("16443", "50001"), ("16444", "50000")):
            result = self.register(name="b", env="b", kube_port=kube, talos_port=talos)
            self.assertEqual(result.returncode, 1)
            self.assertIn("already used by cluster a", result.stderr)
        self.assertNotIn("b", json.loads((self.kube / "config.talos.yaml").read_text())["clusters"])

    def test_public_registration_creates_a_verified_context_and_stages_private_endpoints(self):
        result = self.register("--bootstrap-public")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = self.config()
        self.assertEqual(config["clusters"], [{"name": "a", "cluster": {
            "server": "https://talos-1.elb.amazonaws.com:6443", "certificate-authority-data": self.ca}}])
        self.assertEqual(config["users"][0]["user"]["exec"]["args"][-2:], ["--transport", "bootstrap_public"])
        self.assertNotIn("client-key-data", json.dumps(config))
        self.assertEqual(self.user_file().read_text().splitlines()[-1], "    transport: bootstrap_public")
        entry = json.loads((self.kube / "config.talos.yaml").read_text())["clusters"]["a"]
        self.assertEqual(entry["bootstrap_public_node"], "10.0.1.5")
        self.assertEqual(entry["talos_endpoints"], ["10.0.0.5", "10.0.1.5"])

        self.user_file().write_text(self.user_file().read_text().replace("bootstrap_public", "vpn"))
        result = self.run_cli("merge")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = self.config()
        self.assertEqual(config["clusters"][0]["cluster"]["server"], "https://api.example.internal:6443")
        self.assertEqual(config["users"][0]["user"]["exec"]["args"][-2:], ["--transport", "vpn"])

    def test_invalid_public_hostname_changes_neither_registry_nor_context(self):
        self.env["TEST_PUBLIC_HOST"] = "https://example.com"
        result = self.register("--bootstrap-public")
        self.assertEqual(result.returncode, 1)
        self.assertIn("load balancer hostname", result.stderr)
        self.assertFalse((self.kube / "config.talos.yaml").exists())
        self.assertFalse((self.kube / "config").exists())

    def test_merge_preserves_other_entries_and_replaces_same_name(self):
        self.assertEqual(self.register().returncode, 0)
        config = self.config()
        config["clusters"].append({"name": "keep", "cluster": {"server": "https://keep"}})
        config["users"].append({"name": "keep", "user": {"token": "t"}})
        config["contexts"].append({"name": "keep", "context": {"cluster": "keep", "user": "keep"}})
        config["clusters"][0]["cluster"]["server"] = "https://stale"
        config["current-context"] = "keep"
        (self.kube / "config").write_text(json.dumps(config))
        result = self.run_cli("merge")
        self.assertEqual(result.returncode, 0, result.stderr)
        merged = self.config()
        self.assertEqual(merged["current-context"], "keep")
        self.assertEqual(sorted(c["name"] for c in merged["clusters"]), ["a", "keep"])
        self.assertEqual(sum(c["name"] == "a" for c in merged["clusters"]), 1)
        self.assertEqual(next(c for c in merged["clusters"] if c["name"] == "a")["cluster"]["server"],
                         "https://127.0.0.1:16443")
        self.assertEqual(next(u for u in merged["users"] if u["name"] == "keep")["user"], {"token": "t"})

    def test_merge_does_not_set_current_context_and_uses_absolute_module(self):
        self.assertEqual(self.register().returncode, 0)
        config = self.config()
        self.assertEqual(config["current-context"], "")
        exec_config = config["users"][0]["user"]["exec"]
        self.assertEqual(exec_config["command"], "python3")
        self.assertEqual(exec_config["interactiveMode"], "Never")
        args = exec_config["args"]
        self.assertEqual(args[0], str(SCRIPT.parent / "cluster_access.py"))
        self.assertEqual(args[1], "--exec-credential")
        self.assertEqual(args[args.index("--module") + 1], str(self.root / "env/a"))
        self.assertEqual(args[args.index("--profile") + 1], "prof-a")
        self.assertEqual(args[args.index("--kube-port") + 1], "16443")

    def test_merge_skips_cluster_missing_from_user_file(self):
        self.assertEqual(self.register().returncode, 0)
        (self.kube / "config.talos.user.yaml").write_text("# empty\n")
        (self.kube / "config").unlink()
        result = self.run_cli("merge")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr.count("\n"), 1)
        self.assertIn("config.talos.user.yaml", result.stderr)
        self.assertEqual(self.config()["clusters"], [])

    def test_merge_accepts_hand_edited_user_file(self):
        self.assertEqual(self.register().returncode, 0)
        (self.kube / "config.talos.user.yaml").write_text(
            "clusters:\n  - name: a  # mine\n    aws_profile: \"hand\"\n")
        self.assertEqual(self.run_cli("merge").returncode, 0)
        args = self.config()["users"][0]["user"]["exec"]["args"]
        self.assertEqual(args[args.index("--profile") + 1], "hand")

    def test_unchanged_merge_does_not_rewrite(self):
        self.assertEqual(self.register().returncode, 0)
        before = (self.kube / "config").stat()
        time.sleep(0.05)
        self.assertEqual(self.run_cli("merge").returncode, 0)
        after = (self.kube / "config").stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))

    def test_vpn_register_and_merge_keep_transport_context_and_recovery(self):
        self.kube.mkdir()
        self.user_file().write_text("- name: a\n  aws_profile: vpn-profile\n  transport: vpn\n")
        result = self.register("--vpn-endpoints")
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.config()
        output["current-context"] = "a-ssm"
        path = self.kube / "config"
        path.write_text(json.dumps(output))
        self.env["TEST_PRIVATE_URL"] = "https://updated.example.internal:6443"
        result = self.register()
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.config()
        self.assertEqual(output["current-context"], "a-ssm")
        clusters = {entry["name"]: entry["cluster"] for entry in output["clusters"]}
        self.assertEqual(clusters, {
            "a": {"server": "https://updated.example.internal:6443", "certificate-authority-data": self.ca},
            "a-ssm": {"server": "https://127.0.0.1:16443", "certificate-authority-data": self.ca},
        })
        for user in output["users"]:
            self.assertEqual(set(user["user"]), {"exec"})
            args = user["user"]["exec"]["args"]
            self.assertEqual(args[args.index("--cluster") + 1], "a")
            self.assertEqual(args[args.index("--profile") + 1], "vpn-profile")
            self.assertEqual("--transport" in args, user["name"] == "a")
        before = path.read_bytes()
        for _ in range(2):
            self.assertEqual(self.run_cli("merge").returncode, 0)
            self.assertEqual(path.read_bytes(), before)
        self.assertIn("transport: vpn", self.user_file().read_text())

    def test_vpn_merge_rejects_unrelated_recovery_name(self):
        self.assertEqual(self.register("--vpn-endpoints").returncode, 0)
        self.user_file().write_text("- name: a\n  transport: vpn\n")
        saved = self.config()
        saved["contexts"].append({"name": "a-ssm", "context": {"cluster": "external", "user": "external"}})
        path = self.kube / "config"
        path.write_text(json.dumps(saved))
        result = self.run_cli("merge")
        self.assertEqual(result.returncode, 1)
        self.assertIn("a-ssm", result.stderr)
        self.assertEqual(self.config(), saved)

    def test_invalid_vpn_transport_or_endpoint_fails_without_rewriting(self):
        self.assertEqual(self.register().returncode, 0)
        for transport, message in (("invalid", "transport"), ("vpn", "kube_api_server")):
            self.user_file().write_text(f"- name: a\n  transport: {transport}\n")
            result = self.run_cli("merge")
            self.assertEqual(result.returncode, 1)
            self.assertIn(message, result.stderr)

    def test_help_exits_zero(self):
        self.assertEqual(self.run_cli("--help").returncode, 0)


if __name__ == "__main__":
    unittest.main()
