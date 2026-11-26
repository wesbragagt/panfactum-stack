import json
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from controller_provider_id import main, reconcile


IP = "10.0.1.10"
PROVIDER_ID = "aws:///us-east-2a/i-00000000000000001"


def node(name, *, address=IP, controller=True, provider_id=None):
    return {
        "metadata": {
            "name": name,
            "uid": f"{name}-uid",
            "resourceVersion": "100",
            "labels": {"node-role.kubernetes.io/control-plane": ""} if controller else {},
        },
        "spec": {} if provider_id is None else {"providerID": provider_id},
        "status": {"addresses": [{"type": "InternalIP", "address": address}]},
    }


def node_list(*nodes):
    return json.dumps({"items": nodes})


class ControllerProviderIDTest(unittest.TestCase):
    def test_uses_shared_kubernetes_server_and_tls_name(self):
        routes = (
            ("https://127.0.0.1:26443", "api.test.internal"),
            ("https://test.elb.amazonaws.com:6443", ""),
            ("https://api.test.internal:6443", ""),
        )
        for server, tls_name in routes:
            environment = {
                "CONTROLLER_IDENTITY": json.dumps({"private_ip": IP, "provider_id": PROVIDER_ID}),
                "KUBECONFIG_RAW": "fixture-kubeconfig",
                "KUBE_API_SERVER": server,
                "KUBE_TLS_SERVER_NAME": tls_name,
            }
            with self.subTest(server=server), patch.dict(os.environ, environment, clear=True), \
                    patch("controller_provider_id.subprocess.run") as run:
                run.return_value.stdout = node_list(node("short", provider_id=PROVIDER_ID))

                self.assertEqual(main(), 0)

                command = [
                    "kubectl", "--kubeconfig=/dev/stdin", "--request-timeout=10s",
                    f"--server={server}",
                ]
                if tls_name:
                    command.append(f"--tls-server-name={tls_name}")
                run.assert_called_once_with(
                    [*command, "get", "nodes", "-o", "json"],
                    input="fixture-kubeconfig", text=True, capture_output=True, timeout=12, check=True,
                )

    def test_patches_blank_id_on_existing_short_name_node(self):
        kubectl = Mock(side_effect=[node_list(node("ip-10-0-1-10")), ""])

        reconcile(kubectl, IP, PROVIDER_ID)

        patch_args = kubectl.call_args.args
        self.assertEqual(patch_args[:4], ("patch", "node", "ip-10-0-1-10", "--type=json"))
        self.assertEqual(json.loads(patch_args[4].removeprefix("--patch=")), [
            {"op": "test", "path": "/metadata/uid", "value": "ip-10-0-1-10-uid"},
            {"op": "test", "path": "/metadata/resourceVersion", "value": "100"},
            {"op": "add", "path": "/spec/providerID", "value": PROVIDER_ID},
        ])

    def test_idempotent_when_node_already_has_id(self):
        kubectl = Mock(return_value=node_list(node("short", provider_id=PROVIDER_ID)))

        reconcile(kubectl, IP, PROVIDER_ID)

        kubectl.assert_called_once_with("get", "nodes", "-o", "json")

    def test_refuses_different_or_duplicate_ids_and_ambiguous_addresses(self):
        cases = [
            (node("short", provider_id="aws:///us-east-2a/i-stale"),),
            (node("short"), node("worker", controller=False)),
            (node("short"), node("other", address="10.0.2.10", provider_id=PROVIDER_ID)),
        ]
        for nodes in cases:
            with self.subTest(nodes=nodes):
                kubectl = Mock(return_value=node_list(*nodes))

                with self.assertRaises(ValueError):
                    reconcile(kubectl, IP, PROVIDER_ID, attempts=1)

                kubectl.assert_called_once_with("get", "nodes", "-o", "json")

    def test_refuses_non_controller_with_matching_address(self):
        kubectl = Mock(return_value=node_list(node("worker", controller=False)))

        with self.assertRaisesRegex(ValueError, "control-plane"):
            reconcile(kubectl, IP, PROVIDER_ID, attempts=1)

        kubectl.assert_called_once_with("get", "nodes", "-o", "json")

    @patch("controller_provider_id.time.sleep")
    def test_waits_for_registration_and_rechecks_after_losing_patch_race(self, sleep):
        kubectl = Mock(side_effect=[
            node_list(),
            node_list(node("short", provider_id="")),
            subprocess.CalledProcessError(1, "kubectl", stderr="JSON patch test failed"),
            node_list(node("short", provider_id=PROVIDER_ID)),
        ])

        reconcile(kubectl, IP, PROVIDER_ID, attempts=3)

        self.assertEqual(kubectl.call_count, 4)
        self.assertEqual(sleep.call_count, 2)
        self.assertEqual(kubectl.call_args.args, ("get", "nodes", "-o", "json"))

    def test_missing_node_fails_without_patch_after_last_attempt(self):
        kubectl = Mock(return_value=node_list())

        with self.assertRaisesRegex(ValueError, IP):
            reconcile(kubectl, IP, PROVIDER_ID, attempts=1)

        kubectl.assert_called_once_with("get", "nodes", "-o", "json")
