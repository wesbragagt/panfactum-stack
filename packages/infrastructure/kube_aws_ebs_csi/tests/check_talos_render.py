"""Check the pinned EBS CSI chart rendered with Talos caller overrides."""
import sys
from pathlib import Path
import yaml

objects = [x for x in yaml.safe_load_all(Path(sys.argv[1]).read_text()) if x]
node = next(x for x in objects if x['kind'] == 'DaemonSet' and x['metadata']['name'] == 'ebs-csi-node')
spec = node['spec']['template']['spec']
driver = next(c for c in spec['containers'] if c['name'] == 'ebs-plugin')
assert '--metadata-sources=kubernetes' in driver['args']
assert not any(v.get('hostPath', {}).get('path', '').startswith(('/sys/fs/selinux', '/etc/selinux')) for v in spec['volumes'])
assert {'name': 'AWS_EC2_METADATA_DISABLED', 'value': 'true'} in driver['env']
assert spec['terminationGracePeriodSeconds'] == 110
controller = next(x for x in objects if x['kind'] == 'Deployment' and x['metadata']['name'] == 'ebs-csi-controller')
cs = controller['spec']['template']['spec']['containers']
assert not any(c['name'] == 'csi-snapshotter' for c in cs)
plugin = next(c for c in cs if c['name'] == 'ebs-plugin')
assert {'name': 'AWS_REGION', 'value': 'us-east-2'} in plugin['env']
assert {'name': 'AWS_EC2_METADATA_DISABLED', 'value': 'true'} in plugin['env']
assert plugin['image'].endswith(':v1.45.0')
assert controller['spec']['replicas'] == 1
print('Pinned EBS chart Talos metadata, mount, region, version and snapshot checks passed')
