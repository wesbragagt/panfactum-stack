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
if [ "$2" = -json ] && [ -z "$3" ]; then
  cat "$PWD/outputs.json" || exit 1
  exit 0
fi
case "$3" in
  cluster_url) printf '%s' "${TEST_PRIVATE_URL:-https://api.example.internal:6443}" ;;
  control_plane_private_ips) printf '%s' '["10.0.0.5","10.0.1.5"]' ;;
  bootstrap_public_host) printf '%s' "${TEST_PUBLIC_HOST:-talos-1.elb.amazonaws.com}" ;;
  bootstrap_public_node) printf '%s' '10.0.1.5' ;;
  stable_api_hostname) test -n "$TEST_STABLE_HOST" && printf '"%s"' "$TEST_STABLE_HOST" || exit 1 ;;
  *) cat "$TEST_KUBECONFIG" ;;
esac
'''


IAM_LOGIN = {
    "issuer": "https://example.tokens.sts.global.api.aws", "audience": "a", "region": "us-east-2",
    "principal_arns": ["arn:aws:iam::123456789012:root"],
    "role_arns": {role: f"arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_{role}_abcd"
                  for role in ("Superuser", "Admin", "Reader", "RestrictedReader")},
}


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
            (self.root / f"environments/{name}").mkdir(parents=True)
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

    def register(self, *options, name="a", env="a", profile="prof-a"):
        """Register, then build and merge from fake outputs, as the apply hook and pf-update-kube-talos do."""
        result = self.run_cli("register", "--cluster", name, "--module", str(self.root / "environments" / env),
                              "--region", "us-east-2", "--profile", profile, *options)
        if result.returncode:
            return result
        public = "--bootstrap-public" in options
        self.write_outputs(env, name,
                           bootstrap_public_host=self.env.get("TEST_PUBLIC_HOST", "talos-1.elb.amazonaws.com")
                           if public else None,
                           bootstrap_public_node="10.0.1.5" if public else None)
        built = self.run_cli("build")
        return built if built.returncode else self.run_cli("merge")

    def config(self):
        return json.loads((self.kube / "config").read_text())

    def test_register_writes_only_module_and_user_entries(self):
        # The stub records any call; register must not run terragrunt.
        (self.tmp / "bin/terragrunt").write_text('#!/bin/sh\ntouch "$0.called"\nexit 1\n')
        result = self.run_cli("register", "--cluster", "a", "--module", str(self.root / "environments/a"),
                              "--region", "us-east-2", "--profile", "prof-a")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pf-update-kube-talos --build to add a", result.stdout)
        self.assertEqual((self.kube / "config.talos.yaml").read_text(), "clusters:\n  - module: a\n")
        self.assertEqual(self.user_file().read_text(), "clusters:\n  - name: a\n    aws_profile: prof-a\n")
        self.assertFalse((self.tmp / "bin/terragrunt.called").exists())
        self.assertFalse((self.kube / "cluster_info.talos").exists())
        self.assertFalse((self.kube / "config").exists())

    def test_register_rerun_changes_no_files(self):
        self.assertEqual(self.run_cli("register", "--cluster", "a", "--module", str(self.root / "environments/a"),
                                      "--region", "us-east-2", "--profile", "prof-a").returncode, 0)
        before = {path.name: (path.read_bytes(), path.stat().st_mtime_ns)
                  for path in (self.kube / "config.talos.yaml", self.user_file())}
        time.sleep(0.05)
        result = self.run_cli("register", "--cluster", "a", "--module", str(self.root / "environments/a"),
                              "--region", "us-east-2", "--profile", "other")
        self.assertEqual(result.returncode, 0, result.stderr)
        after = {path.name: (path.read_bytes(), path.stat().st_mtime_ns)
                 for path in (self.kube / "config.talos.yaml", self.user_file())}
        self.assertEqual(before, after)

    def test_register_rejects_module_outside_environments(self):
        (self.root / "other").mkdir()
        result = self.run_cli("register", "--cluster", "a", "--module", str(self.root / "other"),
                              "--region", "us-east-2")
        self.assertEqual(result.returncode, 1)
        self.assertIn("must be under", result.stderr)
        self.assertFalse((self.kube / "config.talos.yaml").exists())

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
        nested = self.root / "environments/a/.terragrunt-cache/x"
        nested.mkdir(parents=True)
        result = subprocess.run(["python3", str(SCRIPT), "register", "--cluster", "a",
                                 "--module", str(self.root / "environments/a"), "--region", "us-east-2",
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
        module = linked / "environments/a"
        module.mkdir(parents=True)
        result = subprocess.run(["python3", str(linked / "scripts/pf-bootstrap-talos"), "register", "--cluster", "a",
                                 "--module", str(module), "--region", "us-east-2"], cwd=module,
                                env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((linked / ".kube").exists())
        self.write_outputs("a", "a")
        for command in ("build", "merge"):
            result = subprocess.run(["python3", str(self.root / "scripts/pf-bootstrap-talos"), command], cwd=self.root,
                                    env=self.env, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
        args = self.config()["users"][0]["user"]["exec"]["args"]
        self.assertEqual(args[0], str(self.root / "scripts/cluster_access.py"))
        self.assertEqual(args[args.index("--module") + 1], str(self.root / "environments/a"))
        before = (self.kube / "config").read_bytes()
        result = subprocess.run(["python3", str(self.root / "scripts/pf-bootstrap-talos"), "merge"], cwd=self.root,
                                env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.kube / "config").read_bytes(), before)

    def test_public_registration_creates_a_verified_context_and_stages_private_endpoints(self):
        result = self.register("--bootstrap-public")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = self.config()
        self.assertEqual(config["clusters"], [{"name": "a", "cluster": {
            "server": "https://talos-1.elb.amazonaws.com:6443", "certificate-authority-data": self.ca}}])
        self.assertEqual(config["users"][0]["user"]["exec"]["args"][-2:], ["--transport", "bootstrap_public"])
        self.assertNotIn("client-key-data", json.dumps(config))
        self.assertEqual(self.user_file().read_text().splitlines()[-1], "    transport: bootstrap_public")
        entry = json.loads((self.kube / "cluster_info.talos").read_text())["clusters"]["a"]
        self.assertEqual(entry["bootstrap_public_node"], "10.0.1.5")
        self.assertEqual(entry["talos_endpoints"], ["10.0.0.5"])

        self.user_file().write_text(self.user_file().read_text().replace("bootstrap_public", "vpn"))
        result = self.run_cli("merge")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = self.config()
        self.assertEqual(config["clusters"][0]["cluster"]["server"], "https://api.example.internal:6443")
        self.assertEqual(config["users"][0]["user"]["exec"]["args"][-2:], ["--transport", "vpn"])

    def test_invalid_public_hostname_changes_no_context(self):
        self.env["TEST_PUBLIC_HOST"] = "https://example.com"
        result = self.register("--bootstrap-public")
        self.assertEqual(result.returncode, 1)
        self.assertIn("load balancer hostname", result.stderr)
        self.assertFalse((self.kube / "config").exists())

    def test_split_dns_keeps_kubernetes_and_talos_hostnames_on_cutover(self):
        host = "api.a.example.com"
        server = f"https://{host}:6443"
        self.env.update(TEST_PUBLIC_HOST=host, TEST_PRIVATE_URL=server, TEST_STABLE_HOST=host)
        result = self.register("--bootstrap-public")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config()["clusters"][0]["cluster"]["server"], server)
        self.user_file().write_text(self.user_file().read_text().replace("bootstrap_public", "vpn"))
        (self.kube / "cluster_info.talos").unlink()
        result = self.register()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config()["clusters"][0]["cluster"]["server"], server)
        entry = json.loads((self.kube / "cluster_info.talos").read_text())["clusters"]["a"]
        self.assertEqual(entry["stable_api_hostname"], host)
        self.assertNotIn("bootstrap_public_host", entry)

    def test_merge_preserves_other_entries_and_replaces_same_name(self):
        self.kube.mkdir(exist_ok=True)
        self.user_file().write_text("clusters:\n  - name: a\n    aws_profile: prof-a\n    transport: ssm\n")
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
        self.assertEqual(args[args.index("--module") + 1], str(self.root / "environments/a"))
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
        result = self.register()
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
        self.kube.mkdir(exist_ok=True)
        self.user_file().write_text("clusters:\n  - name: a\n    aws_profile: prof-a\n    transport: ssm\n")
        self.assertEqual(self.register().returncode, 0)
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
        info_path = self.kube / "cluster_info.talos"
        info = json.loads(info_path.read_text())
        del info["clusters"]["a"]["kube_api_server"]
        info_path.write_text(json.dumps(info))
        for transport, message in (("invalid", "transport"), ("vpn", "kube_api_server")):
            self.user_file().write_text(f"- name: a\n  transport: {transport}\n")
            result = self.run_cli("merge")
            self.assertEqual(result.returncode, 1)
            self.assertIn(message, result.stderr)

    def write_outputs(self, env, name, **extra):
        outputs = {"cluster_name": name, "cluster_region": "us-east-2", "cluster_ca_data": self.ca,
                   "cluster_url": self.env.get("TEST_PRIVATE_URL", "https://api.example.internal:6443"),
                   "control_plane_private_ips": ["10.0.0.5"],
                   "stable_api_hostname": self.env.get("TEST_STABLE_HOST") or None,
                   "bootstrap_public_host": None, **extra}
        (self.root / "environments" / env / "outputs.json").write_text(
            json.dumps({key: {"value": value} for key, value in outputs.items()}))

    def test_build_writes_cluster_info_from_module_outputs(self):
        self.write_outputs("a", "one", stable_api_hostname="api.example.internal")
        self.write_outputs("b", "two")
        self.kube.mkdir(exist_ok=True)
        (self.kube / "config.talos.yaml").write_text("clusters:\n  - module: a\n  - module: b\n")
        (self.kube / "cluster_info.talos").write_text(json.dumps({"clusters": {"gone": {}}}))
        result = self.run_cli("build")
        self.assertEqual(result.returncode, 0, result.stderr)
        info = json.loads((self.kube / "cluster_info.talos").read_text())["clusters"]
        self.assertEqual(info["one"], {
            "region": "us-east-2", "kube_api_server": "https://api.example.internal:6443",
            "ca_data": self.ca, "talos_endpoints": ["10.0.0.5"], "module": "environments/a",
            "stable_api_hostname": "api.example.internal"})
        self.assertEqual(sorted(info), ["one", "two"])
        self.assertNotIn("bootstrap_public_host", info["two"])

    def test_build_stores_iam_login_only_when_the_module_outputs_it(self):
        self.write_outputs("a", "one", iam_login=IAM_LOGIN)
        self.write_outputs("b", "two", iam_login=None)
        self.kube.mkdir(exist_ok=True)
        (self.kube / "config.talos.yaml").write_text("clusters:\n  - module: a\n  - module: b\n")
        result = self.run_cli("build")
        self.assertEqual(result.returncode, 0, result.stderr)
        info = json.loads((self.kube / "cluster_info.talos").read_text())["clusters"]
        self.assertEqual(info["one"]["iam_login"], IAM_LOGIN)
        self.assertNotIn("iam_login", info["two"])

    def build_and_merge(self, user_text, **outputs):
        self.kube.mkdir(exist_ok=True)
        (self.kube / "config.talos.yaml").write_text("clusters:\n  - module: a\n")
        self.user_file().write_text(user_text)
        self.write_outputs("a", "a", **outputs)
        built = self.run_cli("build")
        self.assertEqual(built.returncode, 0, built.stderr)
        return self.run_cli("merge")

    def test_iam_profile_adds_a_context_and_keeps_existing_contexts_byte_identical(self):
        result = self.build_and_merge("- name: a\n  aws_profile: prof-a\n", iam_login=IAM_LOGIN)
        self.assertEqual(result.returncode, 0, result.stderr)
        before = self.config()
        self.assertEqual(sorted(c["name"] for c in before["contexts"]), ["a", "a-ssm"])
        self.assertFalse((self.kube / "a.iam.json").exists())

        result = self.build_and_merge("- name: a\n  aws_profile: prof-a\n  iam_profile: iam-a\n",
                                      iam_login=IAM_LOGIN)
        self.assertEqual(result.returncode, 0, result.stderr)
        after = self.config()
        for key in ("clusters", "users", "contexts"):
            self.assertEqual([item for item in after[key] if item["name"] != "a-iam"], before[key])
        clusters = {item["name"]: item["cluster"] for item in after["clusters"]}
        self.assertEqual(clusters["a-iam"], {"server": "https://api.example.internal:6443",
                                             "certificate-authority-data": self.ca})
        users = {item["name"]: item["user"] for item in after["users"]}
        self.assertEqual(users["a-iam"], {"exec": {
            "apiVersion": "client.authentication.k8s.io/v1", "command": "python3", "interactiveMode": "Never",
            "args": [str(SCRIPT.parent / "iam_login.py"), "credential", "--config", str(self.kube / "a.iam.json"),
                     "--profile", "iam-a", "--aws-cli", "aws"]}})
        contexts = {item["name"]: item["context"] for item in after["contexts"]}
        self.assertEqual(contexts["a-iam"], {"cluster": "a-iam", "user": "a-iam"})
        self.assertEqual(json.loads((self.kube / "a.iam.json").read_text()), IAM_LOGIN)

    def test_iam_metadata_file_is_rewritten_only_when_its_contents_change(self):
        user = "- name: a\n  aws_profile: prof-a\n  iam_profile: iam-a\n"
        self.assertEqual(self.build_and_merge(user, iam_login=IAM_LOGIN).returncode, 0)
        path, config = self.kube / "a.iam.json", self.kube / "config"
        before = [(file.read_bytes(), file.stat().st_ino, file.stat().st_mtime_ns) for file in (path, config)]
        time.sleep(0.05)
        self.assertEqual(self.run_cli("merge").returncode, 0)
        self.assertEqual(before, [(file.read_bytes(), file.stat().st_ino, file.stat().st_mtime_ns)
                                  for file in (path, config)])
        changed = {**IAM_LOGIN, "audience": "other"}
        self.assertEqual(self.build_and_merge(user, iam_login=changed).returncode, 0)
        self.assertEqual(json.loads(path.read_text()), changed)

    def test_iam_profile_skips_transports_other_than_vpn_with_a_message(self):
        for transport, extra in (("ssm", {}), ("bootstrap_public", {
                "bootstrap_public_host": "talos-1.elb.amazonaws.com", "bootstrap_public_node": "10.0.1.5"})):
            with self.subTest(transport=transport):
                result = self.build_and_merge(
                    f"- name: a\n  aws_profile: prof-a\n  iam_profile: iam-a\n  transport: {transport}\n",
                    iam_login=IAM_LOGIN, **extra)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"a uses transport {transport}; a-iam supports only vpn", result.stderr)
                self.assertNotIn("a-iam", [c["name"] for c in self.config()["contexts"]])
                self.assertFalse((self.kube / "a.iam.json").exists())

    def test_iam_profile_without_cluster_metadata_skips_with_a_message(self):
        result = self.build_and_merge("- name: a\n  aws_profile: prof-a\n  iam_profile: iam-a\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("a has no iam_login metadata", result.stderr)
        self.assertEqual(sorted(c["name"] for c in self.config()["contexts"]), ["a", "a-ssm"])
        self.assertFalse((self.kube / "a.iam.json").exists())

    def test_iam_context_name_cannot_shadow_a_registered_cluster(self):
        self.write_outputs("b", "a-iam")
        (self.kube).mkdir(exist_ok=True)
        (self.kube / "config.talos.yaml").write_text("clusters:\n  - module: a\n  - module: b\n")
        self.user_file().write_text("- name: a\n  aws_profile: prof-a\n  iam_profile: iam-a\n")
        self.write_outputs("a", "a", iam_login=IAM_LOGIN)
        self.assertEqual(self.run_cli("build").returncode, 0)
        result = self.run_cli("merge")
        self.assertEqual(result.returncode, 1)
        self.assertIn("a-iam", result.stderr)
        self.assertFalse((self.kube / "config").exists())

    def test_build_failure_keeps_the_old_file(self):
        self.write_outputs("a", "one")
        self.kube.mkdir(exist_ok=True)
        (self.kube / "config.talos.yaml").write_text("clusters:\n  - module: a\n  - module: b\n")
        old = json.dumps({"clusters": {"old": {}}})
        (self.kube / "cluster_info.talos").write_text(old)
        result = self.run_cli("build")
        self.assertEqual(result.returncode, 1)
        self.assertEqual((self.kube / "cluster_info.talos").read_text(), old)

    def test_reader_fills_default_ports_and_user_transport_defaults_to_vpn(self):
        self.kube.mkdir(exist_ok=True)
        (self.kube / "cluster_info.talos").write_text(json.dumps({"clusters": {"a": {"module": "m"}}}))
        (self.kube / "config.talos.user.yaml").write_text("clusters:\n  - name: a\n")
        spec = importlib.util.spec_from_loader(
            "pf_bootstrap_talos", importlib.machinery.SourceFileLoader("pf_bootstrap_talos", str(SCRIPT)))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        entry = module.read_committed(self.kube / "cluster_info.talos")["a"]
        self.assertEqual((entry["kube_port"], entry["talos_port"]), (16443, 50000))
        self.assertEqual(module.read_user(self.kube / "config.talos.user.yaml")["a"].get("transport", "vpn"), "vpn")
        (self.kube / "cluster_info.talos").write_text("{bad")
        with self.assertRaises(module.SetupError):
            module.read_committed(self.kube / "cluster_info.talos")

    def test_help_exits_zero(self):
        self.assertEqual(self.run_cli("--help").returncode, 0)


if __name__ == "__main__":
    unittest.main()
