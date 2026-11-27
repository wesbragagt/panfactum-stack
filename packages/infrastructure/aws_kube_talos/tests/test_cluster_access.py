import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import unittest.mock
from types import SimpleNamespace

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/cluster_access.py"
spec = importlib.util.spec_from_file_location("cluster_access", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def access(**overrides):
    args = SimpleNamespace(profile=None, region=None, control_plane_name=None, cluster="c",
                           target=None, tunnel_name_pattern="nat-*")
    for key, value in overrides.items():
        setattr(args, key, value)
    return module.Access(args)


class ClusterAccessTest(unittest.TestCase):
    def test_help_works_outside_the_repository_without_tools(self):
        with tempfile.TemporaryDirectory() as empty:
            result = subprocess.run([sys.executable, str(SCRIPT), "--help"], cwd=empty, env={"PATH": ""},
                                    capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--fixed-ssm", result.stdout)

    def test_cluster_is_required(self):
        env = {key: value for key, value in os.environ.items() if key != "TF_VAR_cluster_name"}
        result = subprocess.run([sys.executable, str(SCRIPT), "--ensure"], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("inputs.cluster_name", result.stderr)

    def test_aws_argv_omits_unset_profile_and_region(self):
        argv = access().aws_args("sts", "get-caller-identity")
        self.assertNotIn("--profile", argv)
        self.assertNotIn("--region", argv)
        argv = access(profile="p", region="r").aws_args("sts")
        self.assertEqual(argv[1:5], ["--profile", "p", "--region", "r"])

    def test_terragrunt_output_preserves_only_supported_transport_overrides(self):
        args = SimpleNamespace(profile=None, region=None, module=Path("/module"))
        for inherited, expected in (("vpn", None), ("ssm", "ssm"), ("auto", "auto")):
            with self.subTest(inherited=inherited), tempfile.TemporaryDirectory() as directory, \
                    unittest.mock.patch.dict(os.environ, {"PF_TALOS_TRANSPORT": inherited}), \
                    unittest.mock.patch.object(module, "command", return_value=b"output") as command:
                self.assertEqual(module.terragrunt_output(args, Path(directory), "cluster_name"), b"output")
                self.assertEqual(command.call_args.kwargs["env"].get("PF_TALOS_TRANSPORT"), expected)

    def test_three_controllers_are_returned_in_position_order(self):
        helper = access(target=["i-nat"])
        ips = {0: "10.0.128.10", 1: "10.0.64.10", 2: "10.0.192.10"}
        # AWS returns instances in arbitrary order; position follows the Name tag.
        helper.instances = lambda filters: [
            {"PrivateIpAddress": ips[k], "VpcId": "vpc-1",
             "Tags": [{"Key": "Name", "Value": f"c-control-plane-{k}"}]} for k in (2, 0, 1)]
        self.assertEqual([node["PrivateIpAddress"] for node in helper.controllers(("running",))], ["10.0.128.10", "10.0.64.10", "10.0.192.10"])

    def test_discovery_filters_by_the_control_plane_name_prefix(self):
        helper = access(target=["i-nat"])
        calls = []
        helper.instances = lambda filters: calls.append(filters) or []
        self.assertEqual(helper.controllers(("running",)), [])
        self.assertIn("Name=tag:Name,Values=c-control-plane-*", calls[0])

    def test_unrelated_names_matching_the_prefix_filter_are_ignored(self):
        helper = access(target=["i-nat"])
        helper.instances = lambda filters: [
            {"PrivateIpAddress": "10.0.0.9", "Tags": [{"Key": "Name", "Value": "c-control-plane-"}]},
            {"PrivateIpAddress": "10.0.0.8", "Tags": [{"Key": "Name", "Value": "c-control-plane-0/x"}]},
            {"PrivateIpAddress": "10.0.0.6", "Tags": [{"Key": "Name", "Value": "c-control-plane-PRIVATE_A"}]},
            {"PrivateIpAddress": "10.0.0.7", "Tags": [{"Key": "Name", "Value": "c-control-plane-1"}]}]
        self.assertEqual([node["PrivateIpAddress"] for node in helper.controllers(("running",))], ["10.0.0.7"])

    def test_running_controllers_come_before_pending_ones(self):
        helper = access(target=["i-nat"])
        helper.instances = lambda filters: [
            {"PrivateIpAddress": "10.0.0.1", "State": {"Name": "pending"},
             "Tags": [{"Key": "Name", "Value": "c-control-plane-0"}]},
            {"PrivateIpAddress": "10.0.0.2", "State": {"Name": "running"},
             "Tags": [{"Key": "Name", "Value": "c-control-plane-1"}]}]
        self.assertEqual([node["PrivateIpAddress"] for node in helper.controllers(("pending", "running"))], ["10.0.0.2", "10.0.0.1"])

    def test_explicit_control_plane_name_stays_exact(self):
        helper = access(target=["i-nat"], control_plane_name="c-control-plane-1")
        calls = []
        helper.instances = lambda filters: calls.append(filters) or [
            {"PrivateIpAddress": "10.0.64.10", "Tags": [{"Key": "Name", "Value": "c-control-plane-1"}]}]
        self.assertEqual([node["PrivateIpAddress"] for node in helper.controllers(("running",))], ["10.0.64.10"])
        self.assertIn("Name=tag:Name,Values=c-control-plane-1", calls[0])
        helper.instances = lambda filters: [
            {"PrivateIpAddress": ip, "Tags": [{"Key": "Name", "Value": "c-control-plane-1"}]}
            for ip in ("10.0.64.10", "10.0.64.11")]
        with self.assertRaises(module.AccessError):
            helper.controllers(("running",))

    def test_wildcards_in_the_cluster_name_are_rejected(self):
        helper = access(target=["i-nat"], cluster="c*")
        helper.instances = lambda filters: self.fail("must not query AWS")
        with self.assertRaises(module.AccessError):
            helper.controllers(("running",))

    def test_rotation_tries_the_controller_after_the_failed_one_first(self):
        rotate = module.rotate_after
        self.assertEqual(rotate(["a", "b", "c"], "a"), ["b", "c", "a"])
        self.assertEqual(rotate(["a", "b", "c"], "c"), ["a", "b", "c"])
        self.assertEqual(rotate(["a", "b"], "gone"), ["a", "b"])
        self.assertEqual(rotate(["a", "b"], None), ["a", "b"])


FAKE_AWS = """#!%(python)s
import json, os, socket, sys, time
from pathlib import Path
base = Path(os.environ["FAKE_DIR"])
argv = sys.argv[1:]
def option(name):
    return argv[argv.index(name) + 1]
if "PF_TALOS_AWS_PROFILE" in os.environ:
    assert option("--profile") == os.environ["PF_TALOS_AWS_PROFILE"]
    assert option("--region") == os.environ["PF_TALOS_AWS_REGION"]
if "get-caller-identity" in argv:
    print(json.dumps({"Account": os.environ.get("FAKE_ACCOUNT", "123456789012")}))
elif "ec2" in argv:
    (base / "discovered").touch()
    cluster = os.environ.get("FAKE_CLUSTER", "c")
    name_filter = next(a for a in argv if a.startswith("Name=tag:Name"))
    is_jump = name_filter == f"Name=tag:Name,Values={cluster}-ssm-tunnel"
    assert "Name=vpc-id,Values=vpc-1" in argv
    tags = ([{"Key": "Name", "Value": cluster + "-ssm-tunnel"},
             {"Key": "panfactum.com/cluster", "Value": cluster},
             {"Key": "panfactum.com/module", "Value": "aws_ssm_jump_host"}]
            if is_jump else [{"Key": "Name", "Value": cluster + "-control-plane-0"}])
    node = {"InstanceId": "i-01234567890123456" if is_jump else "i-ctl", "State": {"Name": "running"},
            "PrivateIpAddress": "10.0.0.5", "VpcId": "vpc-1", "Tags": tags}
    instances = [] if not is_jump and (base / "not-launched").exists() else [node]
    print(json.dumps({"Reservations": [{"Instances": instances}]}))
elif "get-document" in argv:
    port = option("--name").split("-")[-1]
    content = {"sessionType": "Port", "parameters": {"localPortNumber": {}},
               "properties": {"type": "LocalPortForwarding", "host": "10.0.0.5", "portNumber": port,
                              "localPortNumber": "{{ localPortNumber }}"}}
    print(json.dumps({"Content": json.dumps(content), "DocumentType": "Session"}))
elif "describe-instance-information" in argv:
    print(json.dumps({"InstanceInformationList": [
        {"InstanceId": "i-01234567890123456", "PingStatus": "Online"}]}))
elif "describe-sessions" in argv:
    sessions = [json.loads(f.read_text()) for f in (base / "sessions").glob("*.json")]
    print(json.dumps({"Sessions": sessions}))
elif "terminate-session" in argv:
    (base / "sessions" / (option("--session-id") + ".json")).unlink(missing_ok=True)
    print("{}")
elif "start-session" in argv:
    with (base / "starts").open("a") as starts:
        starts.write("x\\n")
    number = len((base / "starts").read_text().split())
    forwarded = json.loads(option("--parameters"))
    assert set(forwarded) == {"localPortNumber"}
    session = {"SessionId": "sess-%%d" %% number, "Reason": option("--reason"),
               "local": forwarded["localPortNumber"][0], "remote": option("--document-name").split("-")[-1],
               "host": "10.0.0.5"}
    (base / "sessions" / (session["SessionId"] + ".json")).write_text(json.dumps(session))
    print("Starting session with SessionId: " + session["SessionId"], flush=True)
    if (base / f"fail-forward-{session['remote']}").exists():
        sys.exit(1)
    port = int(json.loads(option("--parameters"))["localPortNumber"][0])
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", port))
    server.listen()
    print(f"Port {port} opened for sessionId {session['SessionId']}", flush=True)
    die = base / f"die-once-{session['remote']}"
    if not die.exists():
        die = base / "die-once"
    if die.exists():
        die.unlink()
        server.settimeout(1.5)
        try:
            server.accept()
        except OSError:
            pass
        sys.exit(1)
    while True:
        server.accept()[0].close()
"""


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def wait_until(condition, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.1)
    return condition()


def pid_alive(pid):
    return module.alive(pid)


class BackgroundTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.state = self.root / "state"
        self.fake = self.root / "fake"
        (self.fake / "sessions").mkdir(parents=True)
        (self.fake / "starts").touch()
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        (bin_dir / "aws").write_text(FAKE_AWS % {"python": sys.executable})
        for name in ("aws", "session-manager-plugin", "kubectl"):
            path = bin_dir / name
            if name != "aws":
                path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", FAKE_DIR=str(self.fake))
        self.port = free_port()
        self.env["PF_TALOS_FIXED_SSM"] = str(self.config("c"))
        self.addCleanup(self.stop_helper)

    def config(self, cluster):
        file = self.root / f"{cluster}.json"
        documents = {str(port): {"name": f"fixed-{port}", "port": port, "host": "10.0.0.5"}
                     for port in (6443, 50000)}
        file.write_text(json.dumps({"cluster": cluster, "account_id": "123456789012", "vpc_id": "vpc-1",
                                    "instance_ids": ["i-01234567890123456"], "controller_ip": "10.0.0.5",
                                    "document_destinations": documents}))
        return file

    def argv(self, *extra, cluster="c"):
        cluster_arg = ["--cluster", cluster] if cluster is not None else []
        return [sys.executable, str(SCRIPT), "--bootstrap", *cluster_arg, "--talos-port", str(self.port),
                "--state-dir", str(self.state), *extra]

    def hook(self, *extra, **kwargs):
        return subprocess.run(self.argv("--background", *extra), env=self.env, capture_output=True,
                              text=True, timeout=30, **kwargs)

    def artifact(self, name):
        return next((self.state / "fixed-ssm").glob(f"*/{name}"), None)

    def record(self):
        path = self.artifact("bootstrap.json")
        return json.loads(path.read_text()) if path is not None and path.exists() else None

    def sessions(self):
        return list((self.fake / "sessions").glob("*.json"))

    def starts(self):
        return len((self.fake / "starts").read_text().split())

    def stop_helper(self):
        record = self.record()
        if record and pid_alive(record["pid"]):
            os.kill(record["pid"], signal.SIGTERM)
            wait_until(lambda: not pid_alive(record["pid"]))

    def test_background_requires_bootstrap(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--cluster", "c", "--background"],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("--background requires --bootstrap", result.stderr)

    def test_hook_returns_fast_and_leaves_a_detached_helper(self):
        began = time.monotonic()
        result = self.hook()
        self.assertLess(time.monotonic() - began, 3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'talos_api_endpoint = "127.0.0.1:{self.port}"', result.stdout)
        self.assertIn("bootstrap.log", result.stdout)
        record = self.record()
        self.assertTrue(pid_alive(record["pid"]))
        self.assertNotEqual(os.getsid(record["pid"]), os.getsid(0))
        self.assertEqual(record["talos_port"], self.port)
        self.assertEqual(oct(self.artifact("bootstrap.log").stat().st_mode & 0o777), "0o600")
        self.assertTrue(wait_until(lambda: len(self.sessions()) == 1))

    def test_helper_exits_and_cleans_its_session_after_the_parent_dies(self):
        parent = subprocess.Popen(
            ["sh", "-c", " ".join([*map(__import__("shlex").quote, self.argv("--background")), "; sleep 600"])],
            env=self.env, stdout=subprocess.DEVNULL)
        self.addCleanup(lambda: (parent.kill(), parent.wait()))
        self.assertTrue(wait_until(lambda: self.record() is not None and len(self.sessions()) == 1))
        pid = self.record()["pid"]
        self.assertEqual(self.record()["parent"], parent.pid)
        parent.kill()
        parent.wait()
        self.assertTrue(wait_until(lambda: not pid_alive(pid), 10))
        self.assertEqual(self.sessions(), [])
        self.assertIsNone(self.record())
        module.require_free_port(self.port)

    def test_foreign_listener_fails_the_hook(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", self.port))
            listener.listen()
            result = self.hook()
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"Local port {self.port} is already in use", result.stderr)
        self.assertIsNone(self.record())

    def test_forward_is_restarted_when_it_dies_while_the_parent_lives(self):
        (self.fake / "die-once").touch()
        result = self.hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(wait_until(lambda: self.starts() >= 2 and len(self.sessions()) == 1, 20))
        self.assertTrue(pid_alive(self.record()["pid"]))
        self.stop_helper()
        self.assertEqual(self.sessions(), [])

    def terragrunt_hook(self, **overrides):
        env = dict(self.env, TF_VAR_cluster_name="fixture-cluster", FAKE_CLUSTER="fixture-cluster",
                   AWS_PROFILE="ignored-profile", AWS_REGION="ignored-region",
                   PF_TALOS_AWS_PROFILE="provider-profile", PF_TALOS_AWS_REGION="us-east-2",
                   PF_TALOS_AWS_ACCOUNT_ID="123456789012", **overrides)
        env["PF_TALOS_FIXED_SSM"] = str(self.config("fixture-cluster"))
        self.kube_port = free_port()
        argv = self.argv("--background", "--terragrunt-hook", "--kube-port", str(self.kube_port), cluster=None)
        return argv, env

    def test_terragrunt_hook_waits_for_an_existing_cluster_then_follows_parent_lifetime(self):
        argv, env = self.terragrunt_hook()
        # Keep the hook and a simulated engine under the same parent PID.
        parent = """
import json, os, socket, subprocess, sys
from pathlib import Path
subprocess.run(sys.argv[3:], check=True, timeout=5)
with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=1):
    record = json.loads(next(Path(sys.argv[2]).glob("fixed-ssm/*/bootstrap.json")).read_text())
    assert record["parent"] == os.getpid(), record
    print(record["pid"])
"""
        result = subprocess.run([sys.executable, "-c", parent, str(self.port),
                                 str(self.state), *argv],
                                env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        pid = int(result.stdout.splitlines()[-1])
        self.assertTrue(wait_until(lambda: not pid_alive(pid), 5))
        self.assertEqual(self.starts(), 2)
        self.assertEqual(self.sessions(), [])
        self.assertIsNone(self.record())

    def test_terragrunt_hook_forwards_talos_and_kubernetes(self):
        argv, env = self.terragrunt_hook()
        result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(wait_until(lambda: len(self.sessions()) == 2, 8))
        forwards = {(item["local"], item["remote"], item["host"]) for item in
                    (json.loads(path.read_text()) for path in self.sessions())}
        self.assertEqual(forwards, {(str(self.port), "50000", "10.0.0.5"),
                                    (str(self.kube_port), "6443", "10.0.0.5")})
        self.assertEqual(self.record()["kube_port"], self.kube_port)
        self.assertTrue(wait_until(lambda: self._listening(self.kube_port), 5))

    def test_terragrunt_hook_reconnects_kube_without_closing_talos(self):
        (self.fake / "die-once-6443").touch()
        argv, env = self.terragrunt_hook()
        result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        talos_session = self.fake / "sessions" / "sess-1.json"
        self.assertEqual(json.loads(talos_session.read_text())["remote"], "50000")
        self.assertTrue(wait_until(lambda: self.starts() == 3 and len(self.sessions()) == 2, 10))
        self.assertTrue(talos_session.is_file())
        self.assertEqual(json.loads((self.fake / "sessions" / "sess-3.json").read_text())["remote"], "6443")

    def test_terragrunt_hook_rejects_a_busy_kube_port(self):
        argv, env = self.terragrunt_hook()
        with socket.socket() as busy:
            busy.bind(("127.0.0.1", self.kube_port))
            busy.listen()
            result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"Local port {self.kube_port} is already in use", result.stderr)
        self.assertEqual(self.starts(), 0)

    @staticmethod
    def _listening(port):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=1).close()
        except OSError:
            return False
        return True

    def test_terragrunt_hook_defers_discovery_for_first_apply(self):
        (self.fake / "not-launched").touch()
        argv, env = self.terragrunt_hook()
        result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Waiting in the background for Talos tunnel discovery", result.stdout)
        self.assertEqual(self.starts(), 0)
        (self.fake / "not-launched").unlink()
        self.assertTrue(wait_until(lambda: len(self.sessions()) == 2, 8))

    def test_terragrunt_hook_rejects_aws_account_mismatch_before_discovery(self):
        argv, env = self.terragrunt_hook(FAKE_ACCOUNT="999999999999")
        result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertIn("resolves to account 999999999999", result.stderr)
        self.assertIsNone(self.record())
        self.assertFalse((self.fake / "discovered").exists())

    def test_terragrunt_hook_requires_provider_configuration(self):
        argv, env = self.terragrunt_hook()
        del env["PF_TALOS_AWS_REGION"]
        result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn("PF_TALOS_AWS_REGION is required", result.stderr)
        self.assertFalse((self.fake / "discovered").exists())

    def test_terragrunt_hook_requires_fixed_configuration(self):
        argv, env = self.terragrunt_hook(TF_VAR_talos_access_transport="ssm", PF_TALOS_TRANSPORT="vpn")
        del env["PF_TALOS_FIXED_SSM"]
        result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Set PF_TALOS_FIXED_SSM", result.stderr)
        self.assertIsNone(self.record())
        self.assertEqual(self.starts(), 0)

    def test_terragrunt_hook_uses_routed_transport_without_ssm(self):
        argv, env = self.terragrunt_hook(TF_VAR_talos_access_transport="vpn", PF_TALOS_TRANSPORT="ssm")
        del env["PF_TALOS_FIXED_SSM"]
        result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(self.record())
        self.assertEqual(self.starts(), 0)

    def test_terragrunt_hook_rejects_mismatched_fixed_configuration(self):
        argv, env = self.terragrunt_hook()
        env["PF_TALOS_FIXED_SSM"] = str(self.config("other-cluster"))
        result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Fix the cluster, AWS scope, host IDs or document map", result.stderr)
        self.assertIsNone(self.record())
        self.assertEqual(self.starts(), 0)

    def test_terragrunt_hook_reports_startup_failure_and_cleans_partial_session(self):
        (self.fake / "fail-forward-6443").touch()
        argv, env = self.terragrunt_hook()
        result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Background Talos helper failed to start", result.stderr)
        self.assertIn("failed to establish the Kubernetes forward", self.artifact("bootstrap.log").read_text())
        self.assertEqual(self.starts(), 2)
        self.assertEqual(self.sessions(), [])
        self.assertIsNone(self.record())


if __name__ == "__main__":
    unittest.main()
