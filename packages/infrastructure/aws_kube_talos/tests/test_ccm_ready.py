from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from ccm_ready import check_node


PRIVATE_IP = "10.0.1.10"
PROVIDER_ID = "aws:///us-east-2a/i-12345678"


class CCMReadyTests(unittest.TestCase):
    def setUp(self):
        self.lease = {
            "holderIdentity": "aws-cloud-controller-manager_123",
            "renewTime": datetime.now(timezone.utc).isoformat(),
            "leaseDurationSeconds": 15,
        }
        self.node = {
            "spec": {"providerID": PROVIDER_ID},
            "status": {
                "addresses": [{"type": "InternalIP", "address": PRIVATE_IP}],
                "conditions": [{"type": "Ready", "status": "False"}],
            },
        }

    def kubectl(self, *args):
        return json.dumps({"spec": self.lease} if args[1] == "lease" else {"items": [self.node]})

    def test_initialized_controller_can_still_need_cilium(self):
        check_node(self.kubectl, PRIVATE_IP, PROVIDER_ID)

    def test_requires_a_live_leader(self):
        self.lease["renewTime"] = (datetime.now(timezone.utc) - timedelta(minutes=2)).isoformat()
        with self.assertRaisesRegex(ValueError, "lease expired"):
            check_node(self.kubectl, PRIVATE_IP, PROVIDER_ID)

    def test_rejects_controller_with_incorrect_provider_id(self):
        self.node["spec"]["providerID"] = "aws:///us-east-2a/i-old12345"
        with self.assertRaisesRegex(ValueError, "expected aws:///us-east-2a/i-12345678"):
            check_node(self.kubectl, PRIVATE_IP, PROVIDER_ID)

    def test_waits_for_cloud_uninitialized_taint_removal(self):
        self.node["spec"]["taints"] = [{"key": "node.cloudprovider.kubernetes.io/uninitialized"}]
        with self.assertRaisesRegex(ValueError, "still has the cloud uninitialized taint"):
            check_node(self.kubectl, PRIVATE_IP, PROVIDER_ID)
