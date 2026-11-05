"""Render the actual Raft configuration for default and single-node topologies."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

TEMPLATE = Path(__file__).resolve().parents[1] / 'ha.hcl'

class RaftTemplateTests(unittest.TestCase):
    def render(self, replicas, disable_mlock):
        values = dict(vault_replicas=replicas, disable_mlock=disable_mlock,
                      aws_region='us-east-2', kms_key_id='test-key',
                      aws_role_arn='arn:aws:iam::111122223333:role/test')
        expression = 'jsonencode(templatefile(' + json.dumps(str(TEMPLATE)) + ', ' + json.dumps(values) + '))'
        with tempfile.TemporaryDirectory() as directory:
            r = subprocess.run(['tofu', 'console'], cwd=directory, input=expression+'\n',
                               text=True, capture_output=True, check=True)
        return json.loads(json.loads(r.stdout.strip()))

    def test_default_three_peers_and_implicit_mlock(self):
        config = self.render(3, None)
        self.assertEqual(config.count('leader_api_addr'), 3)
        self.assertIn('vault-2.vault-internal', config)
        self.assertNotIn('disable_mlock', config)

    def test_single_node_keeps_only_real_peer_and_explicit_mlock(self):
        config = self.render(1, True)
        self.assertEqual(config.count('leader_api_addr'), 1)
        self.assertNotIn('vault-1.vault-internal', config)
        self.assertIn('disable_mlock = true', config)
        self.assertIn('web_identity_token_file', config)
        self.assertIn('seal "awskms"', config)

if __name__ == '__main__':
    unittest.main()
