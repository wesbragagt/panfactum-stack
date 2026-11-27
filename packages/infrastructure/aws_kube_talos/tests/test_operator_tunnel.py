import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, Mock, call, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import cluster_access
import operator_tunnel


class OperatorTunnelTest(unittest.TestCase):
    cluster = "operator-canary"
    jump = "i-01234567890123456"
    nat = "i-01234567890123457"
    secondary = "i-01234567890123458"
    controller = "10.0.128.20"
    other_controller = "10.0.192.20"
    kube_host = "api.operator-canary.internal"
    vpc = "vpc-01234567890123456"
    account = "123456789012"
    region = "us-east-2"

    def access(self, **overrides):
        access = operator_tunnel.OperatorAccess(SimpleNamespace(**{
            "cluster": self.cluster, "nat_host": None, "vpc_id": self.vpc,
            "account_id": self.account, "profile": "role", "region": self.region,
            "approved_jump_host": [self.jump], "document_entries": self.documents(), "kube_host": None,
            "preflight": False, "fixed_ssm": Path("fixed.json"), "terragrunt_hook": False,
            "controller_ip": self.controller, "control_plane_name": None, "mode": "operator",
            "kube_port": 26443, "talos_port": 55000, "talosconfig": None, "kube_tls_name": "127.0.0.1",
            "parent": None, "ready_timeout": 1, "reconnect_timeout": 5, **overrides,
        }))
        return access

    def instance(self, name, **overrides):
        return {"VpcId": self.vpc, "InstanceId": self.jump, "PrivateIpAddress": self.controller,
                "State": {"Name": "running"}, "Tags": [
                    {"Key": "Name", "Value": name},
                    {"Key": "panfactum.com/cluster", "Value": self.cluster},
                    {"Key": "panfactum.com/module", "Value": "aws_ssm_jump_host"},
                ], **overrides}

    def document_response(self, host, port):
        return {"DocumentType": "Session", "Content": json.dumps({
            "sessionType": "Port", "parameters": {"localPortNumber": {}}, "properties": {
                "type": "LocalPortForwarding", "host": host, "portNumber": str(port),
                "localPortNumber": "{{ localPortNumber }}",
            },
        })}

    def documents(self, **additional):
        return {
            "kube": {"name": "kube-forward", "host": self.kube_host, "port": 6443},
            "talos-a": {"name": "talos-a-forward", "host": self.controller, "port": 50000},
            "talos-b": {"name": "talos-b-forward", "host": self.other_controller, "port": 50000},
            **additional,
        }

    def test_pending_controller_discovery_refuses_other_vpcs_and_ips(self):
        access = self.access(mode="bootstrap")
        matching = self.instance(f"{self.cluster}-control-plane-0", State={"Name": "pending"})
        access.instances = Mock(return_value=[
            self.instance(f"{self.cluster}-control-plane-0", VpcId="vpc-bad"),
            self.instance(f"{self.cluster}-control-plane-0", PrivateIpAddress="10.0.128.99"),
            self.instance("another-cluster-control-plane-0"), matching,
        ])
        access.discover_hosts = Mock(return_value=[self.jump])
        self.assertEqual(access.discover(("pending", "running")), ([self.controller], [self.jump]))
        access.instances.assert_called_once_with([
            f"Name=tag:Name,Values={self.cluster}-control-plane-*",
            "Name=instance-state-name,Values=pending,running", f"Name=vpc-id,Values={self.vpc}",
        ])
        access.instances.return_value.pop()
        with self.assertRaises(operator_tunnel.ControllerNotFound):
            access.discover(("pending", "running"))

    def test_discovery_only_uses_approved_running_online_hosts_with_exact_tags(self):
        access = self.access(approved_jump_host=[self.jump, self.secondary])
        name = f"{self.cluster}-ssm-tunnel"
        primary = self.instance(name)
        secondary = self.instance(name, InstanceId=self.secondary)
        access.instances = Mock(return_value=[
            secondary, self.instance(name, InstanceId=self.nat), primary,
        ])
        access.aws = Mock(return_value={"InstanceInformationList": [
            {"InstanceId": self.nat, "PingStatus": "Online"},
            {"InstanceId": self.secondary, "PingStatus": "Online"},
            {"InstanceId": self.jump, "PingStatus": "Online"},
        ]})
        self.assertEqual(access.discover(), ([self.controller], [self.jump, self.secondary]))
        self.assertIn("Name=tag:panfactum.com/module,Values=aws_ssm_jump_host", access.instances.call_args.args[0])
        access.aws.return_value["InstanceInformationList"][2]["PingStatus"] = "ConnectionLost"
        self.assertEqual(access.discover_hosts(), [self.secondary])
        secondary["VpcId"] = "vpc-bad"
        with self.assertRaisesRegex(operator_tunnel.NoTunnelHost, "SSM Online"):
            access.discover_hosts()
        primary["Tags"].pop()
        with self.assertRaisesRegex(operator_tunnel.NoTunnelHost, "No approved running jump"):
            access.discover_hosts()

    def test_explicit_nat_stays_pinned(self):
        access = self.access(nat_host=self.nat)
        access.instances = Mock(return_value=[
            self.instance(f"{self.cluster}-ssm-tunnel", InstanceId=self.secondary),
            self.instance("nat-a", InstanceId=self.nat),
        ])
        access.aws = Mock(return_value={"InstanceInformationList": [
            {"InstanceId": self.nat, "PingStatus": "Online"},
            {"InstanceId": self.secondary, "PingStatus": "Online"},
        ]})
        self.assertEqual(access.discover_hosts(), [self.nat])
        self.assertIn(f"Name=instance-id,Values={self.nat}", access.instances.call_args.args[0])

    def test_wrong_or_unreadable_document_never_starts_a_session(self):
        for response in (self.document_response(self.controller, 6443), operator_tunnel.AccessError("denied")):
            with self.subTest(response=response):
                access = self.access()
                access.aws = Mock(side_effect=[{"Account": self.account}, response])
                access.start_session = Mock()
                with self.assertRaisesRegex(operator_tunnel.AccessError, "kube-forward"):
                    access.prepare()
                self.assertEqual(access.aws.call_args, call("ssm", "get-document", "--name", "kube-forward",
                                                           "--document-version", "$DEFAULT", "--document-format", "JSON"))
                access.start_session.assert_not_called()

    def test_explicit_controller_selects_only_its_talos_document(self):
        with tempfile.TemporaryDirectory() as temporary:
            documents = self.documents()
            for controller, document in ((self.controller, "talos-a-forward"),
                                         (self.other_controller, "talos-b-forward")):
                access = self.access(mode="recovery", controller_ip=controller, document_entries=documents)
                access.aws = Mock(side_effect=[
                    {"Account": self.account}, self.document_response(self.kube_host, 6443),
                    self.document_response(controller, 50000),
                ])
                access.prepare()
                access.start_session = Mock()
                directory = Path(temporary)
                for local, remote in ((26443, 6443), (55000, 50000)):
                    access.forward(self.jump, access.destinations[remote].host, directory, local, remote)
                self.assertEqual(access.start_session.call_args_list, [
                    call(self.jump, directory, "kube-forward", {"localPortNumber": ["26443"]}),
                    call(self.jump, directory, document, {"localPortNumber": ["55000"]}),
                ])
            operator = self.access(document_entries=documents, controller_ip=None)
            self.assertEqual(set(operator_tunnel.document_destinations(operator.args)), {6443})

    def test_unknown_or_ambiguous_maps_fail_before_verification(self):
        with tempfile.TemporaryDirectory() as temporary:
            documents = self.documents()
            access = self.access(mode="recovery", controller_ip="10.0.1.1", document_entries=documents)
            access.aws = Mock(return_value={"Account": self.account})
            with self.assertRaisesRegex(operator_tunnel.AccessError, "found 0"):
                access.prepare()
            access.aws.assert_called_once_with("sts", "get-caller-identity")
            documents = self.documents(bootstrap={
                "name": "bootstrap-forward", "host": self.controller, "port": 6443,
            })
            access.args.document_entries = documents
            with self.assertRaisesRegex(operator_tunnel.AccessError, "found 2"):
                operator_tunnel.document_destinations(access.args)
            access.args.controller_ip = self.controller
            access.args.kube_host = self.controller
            chosen = operator_tunnel.document_destinations(access.args)
            self.assertEqual(chosen[6443].name, "bootstrap-forward")

    def test_probe_uses_kubernetes_identity_and_readiness_status(self):
        access = self.access(kube_tls_name=self.kube_host)
        access.kube_tls = MagicMock()
        response = MagicMock()
        with patch.object(operator_tunnel.socket, "create_connection", return_value=MagicMock()) as connect, \
             patch.object(operator_tunnel, "HTTPResponse", return_value=response):
            response.__enter__.return_value.status = 503
            with self.assertRaisesRegex(operator_tunnel.AccessError, "HTTP 503"):
                access.probe(26443, 6443, 2)
            connect.assert_called_once_with(("127.0.0.1", 26443), timeout=2)
            wrapped = access.kube_tls.wrap_socket
            self.assertEqual(wrapped.call_args.kwargs, {"server_hostname": self.kube_host})
            self.assertIn(b"GET /readyz ", wrapped.return_value.__enter__.return_value.sendall.call_args.args[0])
            response.__enter__.return_value.status = 403
            access.probe(26443, 6443, 2)

    def test_probe_can_use_existing_talos_credentials(self):
        access = self.access(mode="recovery", talosconfig=Path("/local/talosconfig"))
        with patch.object(operator_tunnel, "command") as command:
            access.probe(55000, 50000, 2)
        command.assert_called_once_with([
            "talosctl", "--talosconfig", "/local/talosconfig", "--endpoints", "127.0.0.1:55000",
            "--nodes", self.controller, "version", "--short",
        ], timeout=2)

    def test_failover_cleans_partial_sessions_and_reconnects_on_same_ports(self):
        self.assert_reconnect(plugin_exits=True)

    def test_failover_when_online_host_loses_api_route(self):
        self.assert_reconnect(plugin_exits=False)

    def assert_reconnect(self, *, plugin_exits):
        access = self.access(mode="recovery")
        access.destinations = operator_tunnel.document_destinations(access.args)
        access.discover = Mock(return_value=([self.controller], [self.jump, self.secondary]))
        access.discover_hosts = Mock(return_value=[self.jump, self.secondary])
        events = []
        remote_packets = []

        def start(target, directory, document, parameters):
            port = int(parameters["localPortNumber"][0])
            remote_packets.append((target, document, port))
            events.append(("start", target, port))
            log = tempfile.TemporaryFile(dir=directory)
            log.write(f"Port {port} opened for sessionId fixture.\n".encode())
            log.flush()
            access.sessions.append((Mock(poll=Mock(return_value=None)), log))

        clock = [0]
        did_drop = False

        def probe(port, _remote, _timeout):
            target = remote_packets[-1][0]
            if target == self.jump and not did_drop:
                raise OSError("backend is unavailable even though the plugin listened")
            if target == self.secondary and did_drop and not plugin_exits:
                raise OSError("route lost with plugin still running")

        def pause(_args, duration):
            nonlocal did_drop
            clock[0] += duration
            if duration == 0.5 and not did_drop:
                self.assertEqual(remote_packets[-1][0], self.secondary)
                did_drop = True
                if plugin_exits:
                    access.sessions[0][0].poll.return_value = 1
            elif duration == 0.5 and (remote_packets[-1][0] == self.jump or clock[0] > 30):
                raise cluster_access.Interrupted(2)

        def cleanup():
            events.append(("close",))
            for _, log in access.sessions:
                log.close()
            access.sessions.clear()

        access.start_session = Mock(side_effect=start)
        access.close_forwards = Mock(side_effect=cleanup)
        access.probe = probe
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(operator_tunnel, "require_free_port"), \
             patch.object(operator_tunnel, "nap", side_effect=pause), \
             patch.object(operator_tunnel.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(operator_tunnel.signal, "signal"), \
             self.assertRaises(cluster_access.Interrupted):
            access.args.state_dir = Path(temporary)
            operator_tunnel.run_forwards(access.args, access, Path(temporary),
                                         [(26443, 6443), (55000, 50000)], lambda: None)
        self.assertEqual(events, [
            ("start", self.jump, 26443), ("start", self.jump, 55000), ("close",),
            ("start", self.secondary, 26443), ("start", self.secondary, 55000), ("close",),
            ("start", self.jump, 26443), ("start", self.jump, 55000), ("close",),
        ])

    def test_partial_second_forward_is_cleaned_before_trying_next_host(self):
        access = self.access(mode="recovery")
        access.destinations = operator_tunnel.document_destinations(access.args)
        access.forward = Mock(side_effect=[None, OSError("second forward"), None, None])
        access.close_forwards = Mock()
        with patch.object(operator_tunnel, "require_free_port"), \
             patch.object(operator_tunnel, "wait_for_forwards"):
            selected = operator_tunnel.establish(access.args, access, [self.jump, self.secondary],
                                                 Path("."), [(26443, 6443), (55000, 50000)])
        self.assertEqual(selected, self.secondary)
        self.assertEqual([call.args[0] for call in access.forward.call_args_list],
                         [self.jump, self.jump, self.secondary, self.secondary])
        access.close_forwards.assert_called_once()

    def test_reconnect_bounds_aws_discovery_and_exits_if_all_hosts_are_unavailable(self):
        access = self.access(approved_jump_host=[self.jump])
        access.destinations = {}
        clock = [0]
        attempts = []

        def discover_command(_argv, *, timeout):
            attempts.append(timeout)
            if len(attempts) == 1:
                raise operator_tunnel.AccessError("transient describe error")
            clock[0] += timeout
            raise subprocess.TimeoutExpired("aws", timeout)

        def pause(_args, duration):
            clock[0] += duration

        with patch.object(cluster_access, "command", side_effect=discover_command), \
             patch.object(operator_tunnel, "nap", side_effect=pause), \
             patch.object(operator_tunnel.time, "monotonic", side_effect=lambda: clock[0]), \
             self.assertRaisesRegex(operator_tunnel.AccessError, "reconnect timed out: AWS discovery"):
            operator_tunnel.reconnect(access.args, access, Path("."), [(26443, 6443)], self.jump)
        self.assertEqual(attempts, [5, 3])
        self.assertEqual(clock[0], 5)
        self.assertIsNone(access.request_deadline)

    def test_bootstrap_signals_hook_before_controller_exists_and_uses_selected_documents(self):
        access = self.access(mode="bootstrap", terragrunt_hook=True, wait=10)
        access.destinations = operator_tunnel.document_destinations(access.args)
        kube_access = access.separate_sessions()
        access.separate_sessions = Mock(return_value=kube_access)
        order = []
        starts = []

        def discover(states):
            order.append("discovery")
            self.assertEqual(states, ("pending", "running"))
            if order.count("discovery") == 1:
                raise operator_tunnel.ControllerNotFound("still creating")
            return [self.controller], [self.jump]

        def start(tunnel, target, directory, document, parameters):
            starts.append((target, document, parameters))
            port = parameters["localPortNumber"][0]
            log = tempfile.TemporaryFile(dir=directory)
            log.write(f"Port {port} opened for sessionId fixture.\n".encode())
            log.flush()
            self.addCleanup(log.close)
            tunnel.sessions.append((Mock(poll=Mock(return_value=None)), log))

        access.discover = discover
        for tunnel in (access, kube_access):
            tunnel.start_session = lambda *args, tunnel=tunnel: start(tunnel, *args)
            tunnel.probe = Mock()
            tunnel.close_forwards = Mock()
        with patch.object(operator_tunnel, "require_free_port"), \
             patch.object(cluster_access, "nap", side_effect=[None, cluster_access.Interrupted(15)]), \
             patch.object(operator_tunnel.signal, "signal"), \
             self.assertRaises(cluster_access.Interrupted):
            cluster_access.background_run(access.args, access, None, lambda: order.append("hook ready"))
        self.assertEqual(order, ["hook ready", "discovery", "discovery"])
        self.assertEqual(starts, [
            (self.jump, "talos-a-forward", {"localPortNumber": ["55000"]}),
            (self.jump, "kube-forward", {"localPortNumber": ["26443"]}),
        ])
        for tunnel in (access, kube_access):
            tunnel.probe.assert_not_called()
            tunnel.close_forwards.assert_called_once()


if __name__ == "__main__":
    unittest.main()
