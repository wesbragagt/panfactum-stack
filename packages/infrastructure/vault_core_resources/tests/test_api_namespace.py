"""Evaluate VSO values; the Vault API namespace must not change Kubernetes placement."""
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NamespaceTests(unittest.TestCase):
    def values(self, namespace=None):
        source = (ROOT / 'main.tf').read_text().split('resource "helm_release" "vault_secrets_operator" {')[1]
        expression = source.split('  values = ', 1)[1].split('\n}\n', 1)[0]
        fixtures = {
            'module.util_secrets_operator.tolerations': [],
            'module.util_secrets_operator.affinity': {}, 'var.log_level': 'error',
            'vault_mount.transit.path': 'transit',
            'vault_transit_secret_backend_key.secrets_operator.name': 'vso',
            'vault_auth_backend.kubernetes.path': 'kubernetes',
            'module.vault_auth_vault_secrets_operator.role_name': 'vso',
            'local.vault_secrets_operator_service_account': 'vault-secrets-operator',
            'local.namespace': 'vault',
        }
        for key, value in fixtures.items():
            expression = expression.replace(key, json.dumps(value))
        variable = re.search(r'variable "vault_api_namespace" \{.*?\n}', (ROOT / 'vars.tf').read_text(), re.S)[0]
        config = variable + '\nlocals {\n values = ' + expression + '\n}'
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'main.tf').write_text(config)
            if namespace is not None:
                Path(directory, 'terraform.tfvars.json').write_text(json.dumps({'vault_api_namespace': namespace}))
            result = subprocess.run(['tofu', 'console'], cwd=directory, input='jsonencode(yamldecode(local.values[0]))\n', text=True, capture_output=True, check=True)
        return json.loads(json.loads(result.stdout))

    def test_default_and_root_namespace(self):
        legacy, root = self.values(), self.values('')
        for values, expected in [(legacy, 'vault'), (root, '')]:
            self.assertEqual(values['defaultAuthMethod']['namespace'], expected)
            self.assertEqual(values['controller']['manager']['clientCache']['storageEncryption']['namespace'], expected)
        root['defaultAuthMethod']['namespace'] = 'vault'
        root['controller']['manager']['clientCache']['storageEncryption']['namespace'] = 'vault'
        self.assertEqual(legacy, root)
        source = (ROOT / 'main.tf').read_text()
        self.assertIn('namespace       = local.namespace', source)
        self.assertIn('namespace                              = "vault"', source)


if __name__ == '__main__':
    unittest.main()
