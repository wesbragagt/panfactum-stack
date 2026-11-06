#!/usr/bin/env python3
"""Verify pinned Velero chart contracts, not a live backup or module plan."""
import json
from pathlib import Path
import subprocess
import tempfile
import yaml

with tempfile.TemporaryDirectory(prefix='velero-chart-contract-') as directory:
    folder=Path(directory)
    subprocess.run(['helm','pull','velero','--repo','https://vmware-tanzu.github.io/helm-charts','--version','9.1.3','--destination',str(folder)],check=True)
    base={
        'fullnameOverride':'velero',
        'credentials':{'useSecret':False},
        'cleanUpCRDs':True,'upgradeCRDs':True,
        'kubectl':{'image':{'repository':'docker.io/bitnamilegacy/kubectl'}},
        'configuration':{
            'backupStorageLocation':[{'name':'s3','provider':'velero.io/aws','bucket':'render-only-backup-bucket','config':{'region':'us-east-2'}}],
            'volumeSnapshotLocation':[{'name':'s3','provider':'velero.io/aws','config':{'region':'us-east-2'}}],
            'defaultBackupStorageLocation':'s3',
            'defaultVolumeSnapshotLocations':'velero.io/aws:s3',
        },
    }
    def render(values):
        (folder/'values.json').write_text(json.dumps(values))
        r=subprocess.run(['helm','template','velero',str(folder/'velero-9.1.3.tgz'),'--include-crds','--namespace','velero','--kube-version','1.37.1','--values',str(folder/'values.json')],capture_output=True,text=True,check=True)
        return [x for x in yaml.safe_load_all(r.stdout) if x]
    objects=render(base)
    deployment=next(x for x in objects if x['kind']=='Deployment')
    assert deployment['spec']['template']['spec']['containers'][0]['image']=='velero/velero:v1.16.0'
    bsl=next(x for x in objects if x['kind']=='BackupStorageLocation')
    vsl=next(x for x in objects if x['kind']=='VolumeSnapshotLocation')
    assert bsl['metadata']['name']==vsl['metadata']['name']=='s3'
    assert bsl['spec']['config']['region']==vsl['spec']['config']['region']=='us-east-2'
    args=deployment['spec']['template']['spec']['containers'][0]['args']
    assert '--default-volume-snapshot-locations=velero.io/aws:s3' in args
    jobs=[x for x in objects if x['kind']=='Job']
    assert any('pre-delete' in x['metadata'].get('annotations',{}).get('helm.sh/hook','') for x in jobs)
    upgrade=next(x for x in jobs if x['metadata']['name']=='velero-upgrade-crds')
    assert upgrade['spec']['template']['spec']['initContainers'][0]['image']=='docker.io/bitnamilegacy/kubectl:1.37'
    # First install can use CRDs packaged by the pinned chart with hooks disabled.
    # Helm itself does not upgrade packaged CRDs on future upgrades.
    minimal=json.loads(json.dumps(base));minimal.update({'cleanUpCRDs':False,'upgradeCRDs':False})
    objects=render(minimal)
    assert any(x['kind']=='CustomResourceDefinition' for x in objects)
    assert not any(x['kind']=='Job' and any(v in x['metadata'].get('annotations',{}).get('helm.sh/hook','') for v in ['pre-delete','pre-install','pre-upgrade']) for x in objects)
    assert not any(x['kind']=='DaemonSet' for x in objects), 'No node-agent host paths by default'
    assert not any(x['kind']=='Secret' for x in objects), 'IRSA should not render static credential Secrets'
    print('PASS: Velero1.16.0, matching s3 storage/snapshot locations, cleanup hook toggle, no-nodeagent/no-staticSecret, packaged CRDs available on initial install')
    print('LIMIT: default upgrade helper renders unavailable bitnamilegacy/kubectl:1.37; explicit compatible helper or separately managed CRD upgrades required')
