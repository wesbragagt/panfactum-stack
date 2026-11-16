#!/usr/bin/env python3
"""Evaluate the actual release preconditions against scratch state, no providers."""
import re
import subprocess
from test_platform import PlatformTests, ROOT

PlatformTests.setUpClass()
try:
    path = PlatformTests.path
    source = (ROOT / 'main.tf').read_text()
    lifecycle = source.split('  lifecycle {', 1)[1].split('\n  }', 1)[0]
    (path / 'guard.tf').write_text('resource "terraform_data" "guard" {\n lifecycle {' + lifecycle + '\n}\n}\n')
    subprocess.run(['tofu', '-chdir='+str(path), 'init', '-backend=false', '-no-color'], check=True, text=True)
    for missing in ('both', 'arn', 'issuer'):
        args = ['tofu', '-chdir='+str(path), 'plan', '-no-color', '-lock=false', '-var=cluster_type=talos', '-var=ipam_mode=eni', '-var=eni_cluster_tag=canary']
        if missing == 'arn': args += ['-var=oidc_issuer_url=https://canary.example']
        if missing == 'issuer': args += ['-var=oidc_provider_arn=arn:aws:iam::123456789012:oidc-provider/canary.example']
        result = subprocess.run(args, text=True, capture_output=True)
        assert result.returncode != 0
        assert 'Talos ENI requires oidc_provider_arn, oidc_issuer_url' in result.stderr
        print('Missing OIDC '+missing+': expected precondition failure')
        print(result.stderr.strip())
    for extra in ([], ['-var=k8s_service_host=kind-1-control-plane', '-var=k8s_service_port=6443', '-var=ipam_mode=eni']):
        result = subprocess.run(['tofu', '-chdir='+str(path), 'plan', '-no-color', '-lock=false', '-var=cluster_type=local', *extra], text=True, capture_output=True)
        assert result.returncode != 0 and 'Local clusters require a non-ENI ipam_mode' in result.stderr, result.stderr
        print('Local ' + (' '.join(extra) or 'without API host') + ': expected precondition failure')
    result = subprocess.run(['tofu', '-chdir='+str(path), 'plan', '-no-color', '-lock=false', '-var=cluster_type=local', '-var=k8s_service_host=kind-1-control-plane', '-var=k8s_service_port=6443'], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    print('Local with explicit API: precondition passes')
finally:
    PlatformTests.tearDownClass()
