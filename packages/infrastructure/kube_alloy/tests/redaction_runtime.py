import json, pathlib, subprocess, time, urllib.request, socket, os, tempfile
root=pathlib.Path(tempfile.mkdtemp(prefix="alloy-redaction-"))
binary=os.environ["ALLOY_BINARY"]
module=pathlib.Path(__file__).resolve().parent.parent
patterns=json.loads((module/'redaction-patterns.json').read_text())
stages='\n'.join('stage.replace {\n expression = '+json.dumps(p)+'\n replace = "[REDACTED]"\n}' for c in ['credentials','email','ssn','cards'] for p in patterns[c])
config='''logging { level = "info"
 format = "json" }
loki.source.api "test" {
 http { listen_address = "127.0.0.1"\n listen_port = 19123 }
 forward_to = [loki.process.test.receiver]
}
loki.process "test" {
'''+stages+'''
 stage.json { expressions = { level = "" } }
 stage.labels { values = {level = ""} }
 forward_to = [loki.echo.test.receiver]
}
loki.echo "test" {}
'''
(root/'test.alloy').write_text(config)
log=(root/'runtime.log').open('w')
p=subprocess.Popen([binary,'run','--storage.path='+str(root/'data'),'--server.http.listen-addr=127.0.0.1:19124',str(root/'test.alloy')],stdout=log,stderr=log)
try:
 for _ in range(60):
  try:
   urllib.request.urlopen('http://127.0.0.1:19124/-/ready');break
  except Exception: time.sleep(.2)
 fixtures=[{'level':'info','password':'fake spaced \\" secret','nested':{'api_key':'synthetic-key'},'email':'fake@example.invalid','namespace':'default','name':'kube-apiserver','ip':'10.0.0.1','status':200}, {'level':'warn','message':'password=fake-pass bearer fake-bearer user=fake@example.invalid ssn=123-45-6789 card=4111-1111-1111-1111 https://user:fake-url@host'}, {'level':'info','message':json.dumps({'password':'embedded-secret'})}]
 lines=[json.dumps(x) for x in fixtures]+['MULTILINE password=fake-pass\nrequestID=abc123 traceID=def456']
 body=json.dumps({'streams':[{'stream':{'test':'redaction'},'values':[[str(time.time_ns()),x] for x in lines]}]}).encode()
 urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:19123/loki/api/v1/push',data=body,headers={'Content-Type':'application/json'}))
 time.sleep(2)
finally:p.terminate();p.wait();log.close()
text=(root/'runtime.log').read_text()
entries=[json.loads(line) for line in text.splitlines() if line.startswith('{') and '"entry"' in line]
assert len(entries)==len(lines), (len(entries),len(lines))
for entry in entries:
 assert '[REDACTED]' in entry['entry']
 for secret in ['fake spaced','synthetic-key','fake@example.invalid','fake-pass','fake-bearer','123-45-6789','4111-1111-1111','fake-url','embedded-secret']:
  assert secret not in json.dumps(entry), secret
for entry in entries[:3]: json.loads(entry['entry'])
control=json.loads(entries[0]['entry'])
assert control['ip']=='10.0.0.1' and control['status']==200 and control['name']=='kube-apiserver' and control['namespace']=='default'
assert 'level=\"info\"' in entries[0]['labels']
assert 'requestID=abc123 traceID=def456' in entries[3]['entry']
print(f'PASS {len(entries)} actual emitted-line fixtures; JSON, labels, controls and secret absence verified')
