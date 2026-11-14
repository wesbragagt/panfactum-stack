"""Render the real module values with both pinned charts (requires tofu and Helm)."""
import json
import os
from pathlib import Path
import subprocess
import unittest

import test_openbao_contract as contract

ROOT = contract.ROOT


class HelmContractTests(unittest.TestCase):
    console = contract.OpenBaoContractTests.console
    def render(self, engine):
        source = (ROOT / 'main.tf').read_text()
        start = source.index('  values = ') + len('  values = ')
        expression = source[start:source.index('\n\n  timeout', start)]
        # Only substitute infrastructure outputs/inputs, never the chart values.
        fixtures = {
            'module.constants.images.vault.registry': 'ghcr.io',
            'module.constants.images.vault.repository': 'panfactum/vault',
            'module.constants.images.vault.tag': 'fixture',
            'module.constants.cluster_important_priority_class_name': 'cluster-important',
            'module.util_server.labels': {}, 'module.util_server.affinity': {},
            'module.util_server.tolerations': [],
            'module.util_server.topology_spread_constraints': [],
            'module.aws_permissions.role_arn': 'arn:aws:iam::111122223333:role/test',
            'module.unseal_key.id': 'test-key',
            'data.aws_region.region.region': 'us-east-2',
            'kubernetes_service_account.vault.metadata[0].name': 'vault',
            'local.namespace': 'vault', 'path.module': str(ROOT),
            'var.secrets_engine': engine, 'var.monitoring_enabled': False,
            'var.log_level': 'info', 'var.vault_domain': 'vault.example.com',
            'var.vault_storage_size_gb': 20, 'var.vault_replicas': 3,
            'var.disable_mlock': True, 'var.extra_helm_values': {},
        }
        for key, value in fixtures.items():
            expression = expression.replace(key, json.dumps(value))
        values = self.console('locals {\n values = ' + expression + '\n}',
                              'jsonencode(local.values)')
        repo, chart, version = ('https://openbao.github.io/openbao-helm', 'openbao', '0.30.7') if engine == 'openbao' else ('https://helm.releases.hashicorp.com', 'vault', '0.27.0')
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            args = [os.environ.get('HELM', 'helm'), 'template', 'vault', chart,
                    '--repo', repo, '--version', version, '--namespace', 'vault']
            for index, value in enumerate(values):
                path = Path(directory, f'{index}.yaml'); path.write_text(value)
                args.extend(['-f', str(path)])
            result = subprocess.run(args, text=True, capture_output=True, check=True)
        # Helm output is YAML; tofu's yamldecode avoids a Python YAML dependency.
        documents = []
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, 'document.yaml')
            for doc in result.stdout.split('---'):
                if doc.strip():
                    path.write_text(doc)
                    documents.append(self.console('', 'jsonencode(yamldecode(file(' + json.dumps(str(path)) + ')))'))
        return { (doc['kind'], doc['metadata']['name']): doc for doc in documents }

    def check_contract(self, engine):
        docs = self.render(engine)
        sts = docs['StatefulSet', 'vault']
        self.assertEqual(sts['spec']['replicas'], 3)
        self.assertEqual(sts['spec']['serviceName'], 'vault-internal')
        pod = sts['spec']['template']['spec']
        server = pod['containers'][0]
        self.assertEqual(server['name'], engine)
        self.assertIn({'name': 'data', 'mountPath': '/vault/data'}, server['volumeMounts'])
        self.assertEqual(docs['Service', 'vault-active']['spec']['ports'][0]['port'], 8200)
        self.assertEqual(sts['spec']['volumeClaimTemplates'][0]['metadata']['name'], 'data')
        self.assertIn('vault-config', docs['ConfigMap', 'vault-config']['metadata']['name'])
        if engine == 'openbao':
            self.assertEqual(server['image'], 'ghcr.io/openbao/openbao:2.7.2@sha256:5046911075e137e154ce49ab051502f4ec7cf367d484ae4a4dce665d9b90561f')
            self.assertEqual(pod['initContainers'][0]['name'], 'install-openbao-plugins')
            self.assertIn('plugin "kms" "awskms"', docs['ConfigMap', 'vault-config']['data']['extraconfig-from-values.hcl'])
        else:
            self.assertEqual(server['image'], 'ghcr.io/panfactum/vault:fixture')
            self.assertNotIn('initContainers', pod)

    def test_openbao_helm_contract(self):
        self.check_contract('openbao')

    def test_vault_helm_contract(self):
        self.check_contract('vault')


if __name__ == '__main__':
    unittest.main()
