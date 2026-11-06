"""Render pinned chart and check dry-run flags without cluster or AWS access."""
import subprocess
import sys
import yaml

helm = sys.argv[1] if len(sys.argv) > 1 else 'helm'
base = [helm, 'template', 'descheduler', 'descheduler', '--repo',
        'https://kubernetes-sigs.github.io/descheduler/', '--version', '0.35.1',
        '--namespace', 'descheduler', '--kube-version', '1.37.1',
        '--set', 'kind=Deployment', '--set', 'replicas=1']
for enabled in ('true', 'false'):
    result = subprocess.run(base + ['--set-string', f'cmdOptions.dry-run={enabled}'],
                            check=True, capture_output=True, text=True)
    docs = [d for d in yaml.safe_load_all(result.stdout) if d]
    deployment = next(d for d in docs if d['kind'] == 'Deployment')
    assert deployment['spec']['replicas'] == 1
    spec = deployment['spec']['template']['spec']
    assert not spec.get('initContainers')
    container = spec['containers'][0]
    assert container['image'] == 'registry.k8s.io/descheduler/descheduler:v0.35.1'
    flags = [arg for arg in container['args'] if arg.startswith('--dry-run')]
    assert flags == [f'--dry-run={enabled}'], flags
print('Chart 0.35.1 renders explicit dry-run true/false and no init containers.')
