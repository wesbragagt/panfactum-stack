"""Evaluate actual OIDC argument expressions with default and private-CA inputs."""
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class OIDCInputTests(unittest.TestCase):
    def evaluate(self, overrides):
        source = (ROOT / 'main.tf').read_text()
        variables = (ROOT / 'vars.tf').read_text()
        names = ['oidc_discovery_ca_pem', 'oidc_scopes']
        declarations = '\n'.join(re.search(r'variable "' + name + r'" \{.*?\n}', variables, re.S)[0] for name in names)
        bindings = {name: re.search(r'^\s*' + name + r'\s*=\s*(.+)$', source, re.M)[1] for name in names}
        config = declarations + '\nlocals {\n values = {' + ', '.join(name + ' = ' + expression for name, expression in bindings.items()) + '}\n}'
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'main.tf').write_text(config)
            Path(directory, 'terraform.tfvars.json').write_text(json.dumps(overrides))
            result = subprocess.run(['tofu', 'console'], cwd=directory, input='jsonencode(local.values)\n', text=True, capture_output=True, check=True)
        return json.loads(json.loads(result.stdout))

    def test_legacy_defaults(self):
        self.assertEqual(self.evaluate({}), {'oidc_discovery_ca_pem': None, 'oidc_scopes': ['openid', 'profile', 'email']})

    def test_private_ca_and_groups_scope(self):
        inputs = {'oidc_discovery_ca_pem': 'fixture CA PEM', 'oidc_scopes': ['openid', 'profile', 'email', 'groups']}
        self.assertEqual(self.evaluate(inputs), inputs)


if __name__ == '__main__':
    unittest.main()
