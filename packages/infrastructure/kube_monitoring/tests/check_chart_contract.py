"""Check Helm's rendered single-node fixture; does not replace a module plan."""
import sys
import yaml

prom = [x for x in yaml.safe_load_all(open(sys.argv[1])) if x]
thanos = [x for x in yaml.safe_load_all(open(sys.argv[2])) if x]

def one(docs, kind, suffix):
    found = [x for x in docs if x['kind'] == kind and x['metadata']['name'].endswith(suffix)]
    assert len(found) == 1, (kind, suffix, len(found))
    return found[0]

p = one(prom, 'Prometheus', 'monitoring')
assert p['spec']['replicas'] == 1
assert p['spec']['resources']['requests']['memory'] == '512Mi'
assert one(prom, 'Alertmanager', 'monitoring')['spec']['replicas'] == 1

grafana = one(prom, 'Deployment', 'grafana')
assert grafana['spec']['replicas'] == 1
container = next(x for x in grafana['spec']['template']['spec']['containers'] if x['name'] == 'grafana')
assert not any(x['name'] == 'GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET' for x in container.get('env', []))
assert any(x['name'] == 'GF_DATABASE_PASSWORD' for x in container['env'])
ini = one(prom, 'ConfigMap', 'grafana')['data']['grafana.ini']
assert '[auth.generic_oauth]\nauto_login = false\nenabled = false' in ini
assert not any(x['kind'] == 'Ingress' for x in prom)
ksm = one(prom, 'Deployment', 'kube-state-metrics')
assert ksm['spec']['template']['spec']['containers'][0]['resources']['requests']['memory'] == '64Mi'
for kind, suffix in [('Deployment', 'thanos-query'), ('Deployment', 'thanos-query-frontend'), ('StatefulSet', 'thanos-storegateway')]:
    assert one(thanos, kind, suffix)['spec']['replicas'] == 1
assert not any(x['metadata']['name'].endswith('bucketweb') for x in thanos)
print('Single-node Helm chart contract passed (Prometheus, Grafana basic auth, Thanos).')
