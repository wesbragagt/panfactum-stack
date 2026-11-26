import contextlib
import io
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, call, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import operator_tunnel


class OperatorTunnelTest(unittest.TestCase):
    cluster = "operator-canary"
    jump = "i-01234567890123456"
    nat = "i-01234567890123457"
    controller = "10.0.128.20"
    vpc = "vpc-01234567890123456"
    account = "123456789012"
    region = "us-east-2"

    def access(self, **overrides):
        return operator_tunnel.OperatorAccess(SimpleNamespace(**{
            "cluster": self.cluster, "host": self.jump, "nat_host": None, "vpc_id": self.vpc,
            "controller_ip": self.controller, "control_plane_name": None, "mode": "operator",
            "kube_port": 26443, "talos_port": 55000, **overrides,
        }))

    def instance(self, name, **overrides):
        return {"VpcId": self.vpc, "InstanceId": self.jump, "PrivateIpAddress": self.controller,
                "Tags": [{"Key": "Name", "Value": name}], **overrides}

    def cli(self, mode, target, profile="operator-reader"):
        return [mode, "--cluster", self.cluster, "--account-id", self.account,
                "--vpc-id", self.vpc, "--controller-ip", self.controller,
                "--region", self.region, "--profile", profile, *target]

    def test_pending_controller_discovery_ignores_state_and_other_vpcs(self):
        access = self.access()
        matching = self.instance(f"{self.cluster}-control-plane-0", State={"Name": "pending"})
        access.instances = Mock(return_value=[
            self.instance(f"{self.cluster}-control-plane-0", VpcId="vpc-bad"),
            self.instance(f"{self.cluster}-control-plane-0", PrivateIpAddress="10.0.128.99"),
            self.instance("another-cluster-control-plane-0"),
            matching,
        ])
        self.assertEqual(access.discover(("pending", "running")), ([self.controller], [self.jump]))
        access.instances.assert_called_once_with([
            f"Name=tag:Name,Values={self.cluster}-control-plane-*",
            "Name=instance-state-name,Values=pending,running", f"Name=vpc-id,Values={self.vpc}",
        ])

    def test_discovery_refuses_to_use_another_controller_ip(self):
        access = self.access()
        access.instances = Mock(return_value=[
            self.instance(f"{self.cluster}-control-plane-0", PrivateIpAddress="10.0.128.21"),
        ])
        with self.assertRaises(operator_tunnel.ControllerNotFound):
            access.discover(("pending", "running"))

    def test_host_preflight_requires_exact_instance_in_vpc_online(self):
        access = self.access()
        access.instances = Mock(return_value=[self.instance(f"{self.cluster}-ssm-tunnel")])
        access.aws = Mock(return_value={"InstanceInformationList": [
            {"InstanceId": self.nat, "PingStatus": "Online"},
            {"InstanceId": self.jump, "PingStatus": "ConnectionLost"},
        ]})
        with self.assertRaisesRegex(operator_tunnel.AccessError, "is offline in SSM"):
            access.verify_host()
        access.instances.return_value = [self.instance(f"{self.cluster}-ssm-tunnel", VpcId="vpc-bad")]
        with self.assertRaisesRegex(operator_tunnel.AccessError, "Expected running jump"):
            access.verify_host()

    def test_wrong_account_stops_before_host_lookup(self):
        with patch.object(operator_tunnel.shutil, "which", return_value="/bin/fake"), \
             patch.object(operator_tunnel, "OperatorAccess") as access_class, \
             patch.object(operator_tunnel.signal, "signal"), \
             patch("sys.stderr", new_callable=io.StringIO) as stderr:
            access = access_class.return_value
            access.aws.return_value = {"Account": "012345678901"}
            code = operator_tunnel.main(self.cli("bootstrap", ["--jump-host", self.jump]))
        access.aws.assert_called_once_with("sts", "get-caller-identity")
        access.verify_host.assert_not_called()
        self.assertEqual(code, 1)
        self.assertIn("resolves to account", stderr.getvalue())

    def test_bootstrap_handoff_keeps_state_by_profile(self):
        with tempfile.TemporaryDirectory() as temporary, \
             patch.dict(os.environ, {"XDG_STATE_HOME": temporary}), \
             patch.object(operator_tunnel.shutil, "which", return_value="/bin/fake"), \
             patch.object(operator_tunnel, "OperatorAccess") as access_class, \
             patch.object(operator_tunnel.signal, "signal"), \
             patch.object(operator_tunnel, "background", return_value=0) as background:
            access_class.return_value.aws.return_value = {"Account": self.account}
            self.assertEqual(operator_tunnel.main(self.cli("bootstrap", ["--jump-host", self.jump], "profile-a")), 0)
            self.assertEqual(operator_tunnel.main(self.cli(
                "bootstrap", ["--jump-host", self.jump, "--bootstrap-kubernetes"], "profile-b"
            )), 0)
        args_a = background.call_args_list[0].args[0]
        args_b = background.call_args_list[1].args[0]
        self.assertNotEqual(args_a.state_dir, args_b.state_dir)
        self.assertEqual(args_a.state_dir.parent.name, self.cluster)
        self.assertEqual(args_a.host, self.jump)
        self.assertTrue(args_a.terragrunt_hook)
        self.assertFalse(args_a.bootstrap_kubernetes)
        self.assertTrue(args_b.bootstrap_kubernetes)

    def test_operator_rejects_nat_choice(self):
        with contextlib.redirect_stderr(io.StringIO()) as stderr, self.assertRaises(SystemExit) as error:
            operator_tunnel.main(self.cli("operator", ["--nat-host", self.nat]))
        self.assertEqual(error.exception.code, 2)
        self.assertIn("--nat-host requires recovery", stderr.getvalue())

    def test_operator_only_starts_kubernetes_document(self):
        self.assert_sessions("operator", self.jump, [(self.jump, "kube", "26443")])

    def test_recovery_starts_both_documents_on_explicit_nat(self):
        self.assert_sessions("recovery", self.nat, [
            (self.nat, "kube", "26443"), (self.nat, "talos", "55000"),
        ])

    def assert_sessions(self, mode, host, sessions):
        access = self.access(mode=mode, host=host, nat_host=host if host == self.nat else None)
        access.discover = Mock(return_value=([self.controller], [host]))
        access.start_session = Mock()
        access.close_forwards = Mock()
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(operator_tunnel, "require_free_port"), \
             patch.object(operator_tunnel, "wait_for_listeners", side_effect=operator_tunnel.Interrupted(2)), \
             patch.object(operator_tunnel.signal, "signal"), self.assertRaises(operator_tunnel.Interrupted):
            access.args.state_dir = Path(temporary)
            operator_tunnel.operator_tunnel(access.args, access)
        calls = access.start_session.call_args_list
        self.assertEqual(calls, [
            call(target, calls[0].args[1], f"{self.cluster}-{api}-forward", {"localPortNumber": [port]})
            for target, api, port in sessions
        ])
        access.close_forwards.assert_called_once()


if __name__ == "__main__":
    unittest.main()
