import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
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
        self.assertIn("--tunnel-name-pattern", result.stdout)

    def test_cluster_is_required(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--ensure"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)

    def test_aws_argv_omits_unset_profile_and_region(self):
        argv = access().aws_args("sts", "get-caller-identity")
        self.assertNotIn("--profile", argv)
        self.assertNotIn("--region", argv)
        argv = access(profile="p", region="r").aws_args("sts")
        self.assertEqual(argv[1:5], ["--profile", "p", "--region", "r"])

    def test_target_overrides_tunnel_host_discovery(self):
        helper = access(target=["i-1", "i-2"])
        calls = []

        def instances(filters):
            calls.append(filters)
            return [{"PrivateIpAddress": "10.0.0.5", "VpcId": "vpc-1",
                     "Tags": [{"Key": "Name", "Value": "c-control-plane-0"}]}]
        helper.instances = instances
        self.assertEqual(helper.discover(), (["10.0.0.5"], ["i-1", "i-2"]))
        self.assertEqual(len(calls), 1)

    def test_tunnel_name_pattern_filters_the_vpc_lookup(self):
        helper = access(tunnel_name_pattern="bastion-*")
        calls = []

        def instances(filters):
            calls.append(filters)
            return [{"PrivateIpAddress": "10.0.0.5", "VpcId": "vpc-1", "InstanceId": "i-b",
                     "Tags": [{"Key": "Name", "Value": "c-control-plane-0"}]}]
        helper.instances = instances
        helper.aws = lambda *args: {"InstanceInformationList": [{"InstanceId": "i-b", "PingStatus": "Online"}]}
        self.assertEqual(helper.discover()[1], ["i-b"])
        self.assertIn("Name=tag:Name,Values=bastion-*", calls[1])

    def test_three_controllers_are_returned_in_position_order(self):
        helper = access(target=["i-nat"])
        ips = {0: "10.0.128.10", 1: "10.0.64.10", 2: "10.0.192.10"}
        # AWS returns instances in arbitrary order; position follows the Name tag.
        helper.instances = lambda filters: [
            {"PrivateIpAddress": ips[k], "VpcId": "vpc-1",
             "Tags": [{"Key": "Name", "Value": f"c-control-plane-{k}"}]} for k in (2, 0, 1)]
        self.assertEqual(helper.discover()[0], ["10.0.128.10", "10.0.64.10", "10.0.192.10"])

    def test_discovery_filters_by_the_control_plane_name_prefix(self):
        helper = access(target=["i-nat"])
        calls = []
        helper.instances = lambda filters: calls.append(filters) or []
        with self.assertRaises(module.ControllerNotFound):
            helper.discover()
        self.assertIn("Name=tag:Name,Values=c-control-plane-*", calls[0])

    def test_unrelated_names_matching_the_prefix_filter_are_ignored(self):
        helper = access(target=["i-nat"])
        helper.instances = lambda filters: [
            {"PrivateIpAddress": "10.0.0.9", "Tags": [{"Key": "Name", "Value": "c-control-plane-"}]},
            {"PrivateIpAddress": "10.0.0.8", "Tags": [{"Key": "Name", "Value": "c-control-plane-0/x"}]},
            {"PrivateIpAddress": "10.0.0.6", "Tags": [{"Key": "Name", "Value": "c-control-plane-PRIVATE_A"}]},
            {"PrivateIpAddress": "10.0.0.7", "Tags": [{"Key": "Name", "Value": "c-control-plane-1"}]}]
        self.assertEqual(helper.discover()[0], ["10.0.0.7"])

    def test_running_controllers_come_before_pending_ones(self):
        helper = access(target=["i-nat"])
        helper.instances = lambda filters: [
            {"PrivateIpAddress": "10.0.0.1", "State": {"Name": "pending"},
             "Tags": [{"Key": "Name", "Value": "c-control-plane-0"}]},
            {"PrivateIpAddress": "10.0.0.2", "State": {"Name": "running"},
             "Tags": [{"Key": "Name", "Value": "c-control-plane-1"}]}]
        self.assertEqual(helper.discover(("pending", "running"))[0], ["10.0.0.2", "10.0.0.1"])

    def test_explicit_control_plane_name_stays_exact(self):
        helper = access(target=["i-nat"], control_plane_name="c-control-plane-1")
        calls = []
        helper.instances = lambda filters: calls.append(filters) or [
            {"PrivateIpAddress": "10.0.64.10", "Tags": [{"Key": "Name", "Value": "c-control-plane-1"}]}]
        self.assertEqual(helper.discover()[0], ["10.0.64.10"])
        self.assertIn("Name=tag:Name,Values=c-control-plane-1", calls[0])
        helper.instances = lambda filters: [
            {"PrivateIpAddress": ip, "Tags": [{"Key": "Name", "Value": "c-control-plane-1"}]}
            for ip in ("10.0.64.10", "10.0.64.11")]
        with self.assertRaises(module.AccessError):
            helper.discover()

    def test_wildcards_in_the_cluster_name_are_rejected(self):
        helper = access(target=["i-nat"], cluster="c*")
        helper.instances = lambda filters: self.fail("must not query AWS")
        with self.assertRaises(module.AccessError):
            helper.discover()

    def test_establish_fails_over_to_the_next_controller(self):
        helper = access()
        attempts = []

        def start(target, private_ip, directory, tls_context, talos_tls=None):
            attempts.append(private_ip)
            if private_ip == "10.0.0.1":
                raise module.AccessError("TLS timeout")
        helper.start = start
        helper.close_forwards = lambda: None
        ready = []
        result = helper.establish(["10.0.0.1", "10.0.0.2"], ["i-nat"], None, None, None, ready.append)
        self.assertEqual(result, ("i-nat", "10.0.0.2"))
        self.assertEqual(attempts, ["10.0.0.1", "10.0.0.2"])
        self.assertEqual(ready, ["10.0.0.2"])

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
if "ec2" in argv:
    tags = [{"Key": "Name", "Value": "nat-A" if any(a.startswith("Name=vpc-id") for a in argv) else "c-control-plane-0"}]
    node = {"InstanceId": "i-nat" if tags[0]["Value"] == "nat-A" else "i-ctl",
            "PrivateIpAddress": "10.0.0.5", "VpcId": "vpc-1", "Tags": tags}
    print(json.dumps({"Reservations": [{"Instances": [node]}]}))
elif "describe-instance-information" in argv:
    print(json.dumps({"InstanceInformationList": [{"InstanceId": "i-nat", "PingStatus": "Online"}]}))
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
    session = {"SessionId": "sess-%%d" %% number, "Reason": option("--reason")}
    (base / "sessions" / (session["SessionId"] + ".json")).write_text(json.dumps(session))
    print("Starting session with SessionId: " + session["SessionId"], flush=True)
    port = int(json.loads(option("--parameters"))["localPortNumber"][0])
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", port))
    server.listen()
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
        self.addCleanup(self.stop_helper)

    def argv(self, *extra):
        return [sys.executable, str(SCRIPT), "--bootstrap", "--cluster", "c", "--talos-port", str(self.port),
                "--state-dir", str(self.state), "--tunnel-name-pattern", "nat-*", *extra]

    def hook(self, *extra, **kwargs):
        return subprocess.run(self.argv("--background", *extra), env=self.env, capture_output=True,
                              text=True, timeout=30, **kwargs)

    def record(self):
        try:
            return json.loads((self.state / "bootstrap.json").read_text())
        except (OSError, ValueError):
            return None

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
                                capture_output=True, text=True)
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
        self.assertEqual(oct((self.state / "bootstrap.log").stat().st_mode & 0o777), "0o600")
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

    def test_live_ensure_tunnel_on_the_same_port_is_reused(self):
        self.state.mkdir(mode=0o700)
        (self.state / "ready.json").write_text(json.dumps(
            {"pid": os.getpid(), "kubeconfig": "k", "talosconfig": "t", "cluster": "c",
             "kube_port": 1, "talos_port": self.port}))
        result = self.hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"reusing live tunnel for c on 127.0.0.1:{self.port}", result.stdout)
        self.assertIsNone(self.record())
        self.assertEqual(self.starts(), 0)

    def test_live_helper_of_a_running_parent_is_reused(self):
        sleeper = subprocess.Popen(["sleep", "30"])
        self.addCleanup(lambda: (sleeper.kill(), sleeper.wait()))
        self.state.mkdir(mode=0o700)
        record = {"pid": sleeper.pid, "parent": os.getpid(), "talos_port": self.port}
        (self.state / "bootstrap.json").write_text(json.dumps(record))
        result = self.hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reusing background helper", result.stdout)
        self.assertEqual(self.record(), record)
        self.assertEqual(self.starts(), 0)

    def test_exiting_previous_helper_is_waited_out(self):
        gone = subprocess.Popen(["true"])
        gone.wait()
        sleeper = subprocess.Popen(["sleep", "3"])
        threading.Thread(target=sleeper.wait, daemon=True).start()
        self.state.mkdir(mode=0o700)
        (self.state / "bootstrap.json").write_text(json.dumps(
            {"pid": sleeper.pid, "parent": gone.pid, "talos_port": self.port}))
        began = time.monotonic()
        result = self.hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreaterEqual(time.monotonic() - began, 2)
        self.assertFalse(pid_alive(sleeper.pid))
        self.assertNotEqual(self.record()["pid"], sleeper.pid)

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


if __name__ == "__main__":
    unittest.main()
