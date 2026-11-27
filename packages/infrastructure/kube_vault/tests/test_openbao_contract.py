"""Evaluate the real engine overlay and HCL without a cluster or credentials."""
import json
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class OpenBaoContractTests(unittest.TestCase):
    def console(self, configuration, expression):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'main.tf').write_text(configuration)
            result = subprocess.run(['tofu', 'console'], cwd=directory,
                                    input=expression + '\n', text=True,
                                    capture_output=True, check=True)
        return json.loads(json.loads(result.stdout.strip()))

    def values(self, engine, arch='arm64'):
        source = (ROOT / 'main.tf').read_text()
        plugins = re.search(r'\nlocals \{\n  openbao_plugins = .*?\n\}\n', source, re.S).group(0)
        start = source.index('  values = ') + len('  values = ')
        end = source.index('\n\n  timeout', start)
        expression = source[start:end]
        # Replace only the pre-existing common values object and user override
        # expression with sentinels. Evaluate the actual outer values-list and
        # engine-selection expression, including all entry separators.
        common_start = expression.index('yamlencode({')
        common_end = re.search(r'\n\s*\], var.secrets_engine', expression).start()
        common_end = expression.rfind('})', common_start, common_end) + 2
        expression = (expression[:common_start] + 'jsonencode({base="unchanged"})'
                      + expression[common_end:])
        expression = expression.replace('yamlencode(var.extra_helm_values)',
                                        'jsonencode({extra="unchanged"})')
        # The local-simulator overlay (aws_local_endpoint) is null by default; stub its module output.
        expression = expression.replace('module.aws_permissions.local_credentials_secret_name', '"local-static"')
        configuration = ('variable "secrets_engine" { default = ' + json.dumps(engine) + ' }\n'
                         'variable "openbao_plugin_arch" { default = ' + json.dumps(arch) + ' }\n' + plugins +
                         'variable "aws_local_endpoint" { default = null }\n' +
                         'locals {\n  values = ' + expression + '\n}\n')
        return self.console(configuration, 'jsonencode([for value in local.values : yamldecode(value)])')

    def test_amd64_downloads_and_checks_amd64_assets(self):
        default = self.values('openbao')[1]['server']['extraInitContainers'][0]['args'][0]
        amd64 = self.values('openbao', 'amd64')[1]['server']['extraInitContainers'][0]['args'][0]
        self.assertIn('_linux_arm64_v8.tar.gz', default)
        self.assertNotIn('amd64', default)
        self.assertIn('_linux_amd64_v1.tar.gz', amd64)
        self.assertNotIn('arm64', amd64)
        self.assertIn('f00ebed7fa1cbec080e0fed908e167125bc14b266df7e4af845f82aa4650ed4e', amd64)
        self.assertIn('2de810eadea3d5fb65fe055a1fdd2f13889056605502d467928ef4cacd458f2b', amd64)

    def overlay(self, engine):
        return self.values(engine)[1]

    def test_vault_retains_original_two_values_entries(self):
        self.assertEqual(self.values('vault'), [{'base': 'unchanged'}, {'extra': 'unchanged'}])

    def test_openbao_keeps_names_and_checks_plugins(self):
        rendered = self.values('openbao')
        self.assertEqual(len(rendered), 3)
        values = rendered[1]
        self.assertEqual(values['fullnameOverride'], 'vault')
        self.assertEqual(values['nameOverride'], 'vault')
        server = values['server']
        self.assertEqual(server['image']['registry'], 'ghcr.io')
        self.assertTrue(server['image']['tag'].startswith('2.7.2@sha256:'))
        self.assertTrue(server['extraEnvironmentVars']['PATH'].startswith('/compat:'))
        install = server['extraInitContainers'][0]
        script = install['args'][0]
        self.assertEqual(script.count('sha256sum -c -'), 2)
        self.assertLess(script.index('sha256sum -c -'), script.index('tar -xzf'))
        self.assertIn('ln -sf /bin/bao /compat/vault', script)
        subprocess.run(['/bin/sh', '-n'], input=script, text=True, check=True)
        mounts = {mount['mountPath']: mount for mount in server['volumeMounts']}
        self.assertTrue(mounts['/vault/plugins']['readOnly'])
        self.assertTrue(mounts['/compat']['readOnly'])

    def test_openbao_seal_has_plugins_and_workload_identity(self):
        params = dict(vault_replicas=3, disable_mlock=True, aws_region='us-east-2',
                      kms_key_id='test-key', aws_role_arn='arn:aws:iam::111122223333:role/test',
                      aws_endpoint=None, plugin_arch='arm64',
                      kms_sha256='986487f17d30123b4730cf412ad2267f7ef4cfe637c75252ed6d13294673bae2',
                      aws_sha256='670aa9c3f1cff789826ab8c00845760034d8f82afd2cdd57ecf794863e8c7127')
        expression = ('jsonencode(templatefile(' + json.dumps(str(ROOT / 'ha-openbao.hcl'))
                      + ', ' + json.dumps(params) + '))')
        config = self.console('', expression)
        self.assertLess(config.index('plugin "kms" "awskms"'), config.index('seal "awskms"'))
        self.assertIn('plugin "secret" "aws"', config)
        self.assertIn('plugin_auto_download = false', config)
        self.assertIn('AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token', config)
        self.assertIn('vault-2.vault-internal', config)
        seal = config.split('seal "awskms" {', 1)[1].split('}', 1)[0]
        self.assertNotIn('web_identity_token_file', seal)
        self.assertNotIn('role_arn', seal)
        self.assertIn('kms_key_id = "test-key"', seal)


if __name__ == '__main__':
    unittest.main()
