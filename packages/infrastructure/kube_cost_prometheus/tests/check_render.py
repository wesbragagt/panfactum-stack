#!/usr/bin/env python3
"""Render actual Terraform values and pinned Helm chart without a cluster.

Run tofu init -backend=false before this script. Requires tofu, helm and PyYAML.
No Terraform plan/apply or live Kubernetes/AWS operations are performed.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import urllib.request
import yaml

MODULE = Path(__file__).resolve().parents[1]
VERSION = "29.43.0"
EXPECTED_DIGEST = "0db4048f1f56f886385efe9c570e7bcc759e934e8e7f892d4c585c152dedf628"
expression = 'jsonencode(yamldecode(templatefile("${path.module}/values.yaml.tftpl", {namespace="cost-monitoring",storage_class_name="ebs-standard-retained"})))'
console = subprocess.run(['tofu','console'], cwd=MODULE, input=expression+'\n', capture_output=True, text=True, check=True)
values = json.loads(json.loads(console.stdout))
with tempfile.TemporaryDirectory(prefix='cost-prometheus-render-') as directory:
    folder = Path(directory)
    chart = folder/f'prometheus-{VERSION}.tgz'
    url = f'https://github.com/prometheus-community/helm-charts/releases/download/prometheus-{VERSION}/prometheus-{VERSION}.tgz'
    with urllib.request.urlopen(url,timeout=60) as response: chart.write_bytes(response.read())
    assert hashlib.sha256(chart.read_bytes()).hexdigest() == EXPECTED_DIGEST
    (folder/'values.json').write_text(json.dumps(values))
    result = subprocess.run(['helm','template','cost-prometheus',str(chart),'--namespace','cost-monitoring','--kube-version','1.37.1','--values',str(folder/'values.json')],capture_output=True,text=True,check=True)
    objects=[o for o in yaml.safe_load_all(result.stdout) if o]
    assert not any(o['kind'] in ['ServiceMonitor','PodMonitor','Secret','Ingress'] for o in objects)
    assert not any('alertmanager' in o['metadata']['name'] or 'pushgateway' in o['metadata']['name'] for o in objects)
    deployments=[o for o in objects if o['kind']=='Deployment']
    assert len(deployments)==2
    server=next(o for o in deployments if o['metadata']['name']=='cost-prometheus-server')
    assert server['spec']['replicas']==1 and server['spec']['strategy']['type']=='Recreate'
    containers=server['spec']['template']['spec']['containers']; assert len(containers)==1
    c=containers[0]
    assert c['resources']['requests']['memory']=='512Mi' and c['resources']['limits']['memory']=='1Gi'
    assert '--storage.tsdb.retention.time=2d' in c['args']
    assert '--storage.tsdb.retention.size=1500MB' in c['args']
    assert c['image']=='quay.io/prometheus/prometheus:v3.16.0'
    volumes=server['spec']['template']['spec']['volumes']
    assert any(v.get('persistentVolumeClaim',{}).get('claimName')=='cost-prometheus-data' for v in volumes)
    assert not any(o['kind']=='PersistentVolumeClaim' for o in objects), 'Terraform owns the retained PVC'
    ksm=next(o for o in deployments if o['metadata']['name']=='cost-kube-state-metrics')
    assert ksm['spec']['template']['spec']['containers'][0]['resources']['requests']['memory']=='64Mi'
    ds=next(o for o in objects if o['kind']=='DaemonSet')
    assert ds['metadata']['name']=='cost-node-exporter'
    assert ds['spec']['template']['spec']['containers'][0]['resources']['requests']['memory']=='32Mi'
    service=next(o for o in objects if o['kind']=='Service' and o['metadata']['name']=='cost-node-exporter')
    assert service['spec']['ports'][0]['name']=='metrics'
    config=next(o for o in objects if o['kind']=='ConfigMap' and 'prometheus.yml' in o.get('data',{}))
    cfg=yaml.safe_load(config['data']['prometheus.yml'])
    jobs=cfg['scrape_configs']
    print('Rendered jobs:', [j['job_name'] for j in jobs])
    assert {j['job_name'] for j in jobs}=={'prometheus','kubernetes-nodes','kubernetes-cadvisor','kube-state-metrics','node-exporter','opencost'}
    assert all(j['honor_labels'] is True for j in jobs)
    for j in jobs:
        if j['job_name'] in ['kubernetes-nodes','kubernetes-cadvisor']:
            assert j['tls_config']['ca_file'].endswith('/ca.crt') and not j['tls_config'].get('insecure_skip_verify',False)
            assert any(r.get('replacement')=='kubernetes.default.svc:443' for r in j['relabel_configs'])
    for o in objects:
        if o['kind'] in ['ClusterRole','Role']:
            for rule in o.get('rules',[]):
                assert 'secrets' not in rule.get('resources',[]) and '*' not in rule.get('resources',[])
    assert server['spec']['template']['spec']['serviceAccountName']=='cost-prometheus'
    assert any('endpointslices' in rule.get('resources',[]) for o in objects if o['kind']=='ClusterRole' for rule in o.get('rules',[])), 'EndpointSlice discovery needs read RBAC'
    print('PASS: pinned chart digest/app, actual template, retained PVC reference, resource budget, minimal components, six honor-label jobs, CA-verified API proxy and no Secret-reading RBAC')
