"""Pinned/default and compatible/caller chart renders; no cluster/AWS access."""
import pathlib
import subprocess
import sys
import yaml

helm = sys.argv[1] if len(sys.argv) > 1 else 'helm'
fixture = pathlib.Path(__file__).with_name('self-managed.yaml')
for version in ('1.10.0', '1.15.1'):
    result = subprocess.run([helm, 'template', 'karpenter',
                             'oci://public.ecr.aws/karpenter/karpenter', '--version', version,
                             '--namespace', 'karpenter', '--kube-version', '1.37.1',
                             '-f', str(fixture)], check=True, capture_output=True, text=True)
    docs = [d for d in yaml.safe_load_all(result.stdout) if d]
    d = next(d for d in docs if d['kind'] == 'Deployment')
    assert d['spec']['replicas'] == 1
    spec = d['spec']['template']['spec']
    assert spec['serviceAccountName'] == 'karpenter'
    assert not spec.get('initContainers')
    assert d['spec']['template']['metadata']['annotations']['linkerd.io/inject'] == 'disabled'
    c = next(c for c in spec['containers'] if c['name'] == 'controller')
    env = {e['name']: e.get('value') for e in c['env']}
    for key, value in {'AWS_REGION': 'us-east-2', 'AWS_EC2_METADATA_DISABLED': 'true',
                       'CLUSTER_NAME': 'self-managed-render',
                       'CLUSTER_ENDPOINT': 'https://kubernetes.example.invalid:6443',
                       'INTERRUPTION_QUEUE': 'render-only'}.items():
        assert env[key] == value, (version, key, env)
    assert env.get('EKS_CONTROL_PLANE', 'false') == 'false'
    assert c['resources']['requests']['memory'] == '400Mi'
    assert f':{version}@sha256:' in c['image'], c['image']
    print(f'{version}: explicit endpoint/region, no IMDS, one unmeshed controller, pinned image verified.')
