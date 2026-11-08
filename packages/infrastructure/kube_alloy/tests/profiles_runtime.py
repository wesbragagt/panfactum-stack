"""Real pinned Alloy routing/process test; render production Terraform, no regex simulation."""
import json, os, pathlib, subprocess, tempfile, time, urllib.request
module=pathlib.Path(__file__).resolve().parent.parent
binary=os.environ['ALLOY_BINARY']
root=pathlib.Path(tempfile.mkdtemp(prefix='alloy-profiles-'))
for name in ['redaction.tf','redaction-patterns.json','redaction.alloy.tftpl','redaction-profiles.alloy.tftpl']:
 (root/name).write_bytes((module/name).read_bytes())
(root/'vars.tf').write_text((module/'vars.tf').read_text().split('variable "redaction_enabled"',1)[1].join(['variable "redaction_enabled"','']))
def render(expr,enabled):
 p=subprocess.run(['tofu','console','-var=redaction_enabled='+str(enabled).lower(),'-var=redaction_profiles_enabled='+str(enabled).lower()],input='jsonencode('+expr+')',text=True,cwd=root,capture_output=True)
 if p.returncode: raise RuntimeError(p.stderr)
 return json.loads(json.loads(p.stdout))
for enabled in [True,False]:
 stages=render('local.redaction_pod_stages',enabled); rules=render('local.redaction_profile_relabel',enabled).replace("__meta_kubernetes_pod_annotation_panfactum_com_log_redaction_profile", "test_annotation")
 # API source simulates the effective ordinary label after discovery's exact relabel rule.
 # Also run that same production relabel rule in loki.relabel to test whitelist/fallback.
 config='''logging { level = "info"\n format = "json" }
loki.source.api "test" {
 http { listen_address = "127.0.0.1"\n listen_port = 19123 }
 forward_to = [loki.relabel.test.receiver]
}
loki.relabel "test" {
 forward_to = [loki.process.test.receiver]
'''+rules+'''
}
loki.process "test" {
'''+stages+'''
 stage.json { expressions = { level = "" } }
 stage.labels { values = { level = "" } }
 stage.label_drop { values = ["test_annotation"] }
 forward_to = [loki.echo.test.receiver]
}
loki.echo "test" {}
'''
 (root/'test.alloy').write_text(config)
 with (root/'runtime.log').open('w') as log:
  p=subprocess.Popen([binary,'run','--storage.path='+str(root/'data'),'--server.http.listen-addr=127.0.0.1:19124',str(root/'test.alloy')],stdout=log,stderr=log)
  try:
   for _ in range(60):
    try: urllib.request.urlopen('http://127.0.0.1:19124/-/ready');break
    except Exception: time.sleep(.2)
   streams=[]
   for owner in ['Deployment','StatefulSet']:
    for profile in ['standard','strict','','unknown','off']:
     line=json.dumps(dict(level='info',password='SYNTHETIC-password',email='fake@example.test',full_name='SYNTHETIC PERSON',phone='1-202-555-0142',ip_address='10.0.0.1',name='kube-apiserver',status=200,requestID='req123',traceID='trace456',message=json.dumps({'password':'SYNTHETIC-nested'})))
     streams.append({'stream':{'owner':owner,'case':profile or 'missing','test_annotation':profile},'values':[[str(time.time_ns()),line]]})
   urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:19123/loki/api/v1/push',data=json.dumps({'streams':streams}).encode(),headers={'Content-Type':'application/json'}));time.sleep(2)
  finally:p.terminate();p.wait()
 entries=[json.loads(x) for x in (root/'runtime.log').read_text().splitlines() if x.startswith('{') and '"entry"' in x]
 assert len(entries)==10,(root,len(entries))
 for e in entries:
  line=json.loads(e['entry']); strict='case="strict"' in e['labels'] and enabled
  assert 'pf_log_redaction_profile' not in e['labels']
  assert line['ip_address']=='10.0.0.1' and line['name']=='kube-apiserver' and line['requestID']=='req123' and line['traceID']=='trace456' and line['status']==200
  assert (line['full_name']=='[REDACTED]')==strict
  assert (line['phone']=='[REDACTED]')==strict
  assert ('SYNTHETIC-password' not in e['entry'])==enabled
  assert ('SYNTHETIC-nested' not in e['entry'])==enabled
  assert 'level="info"' in e['labels']
 print('PASS',len(entries),'actual emitted profile fixtures; baseline='+str(enabled))
