"""Check a workload-identity core plan JSON supplied over stdin; print no secret fields."""
import json
import sys

plan = json.load(sys.stdin)
changes = [r for r in plan['resource_changes'] if r['mode'] == 'managed']
assert not any(r['type'] in {'aws_iam_user', 'aws_iam_access_key', 'aws_iam_user_policy_attachment'} for r in changes)
assert not any('delete' in r['change']['actions'] for r in changes)
backend = next(r for r in changes if r['type'] == 'vault_aws_secret_backend')['change']['after']
assert backend.get('access_key') in (None, '') and backend.get('secret_key') in (None, '')
attachment = next(r for r in changes if r['address'].startswith('aws_iam_role_policy_attachment.vault_workload_identity'))
assert attachment['change']['after']['role'].startswith('vault-')
policy = next(r for r in changes if r['type'] == 'aws_iam_policy')['change']['after']['policy']
statement = json.loads(policy)['Statement'][0]
resources = statement['Resource']
assert resources.endswith(':user/vault-*') if isinstance(resources, str) else all(r.endswith(':user/vault-*') for r in resources)
print('Workload-identity plan checks passed: no static bootstrap IAM credentials; scoped role policy.')
