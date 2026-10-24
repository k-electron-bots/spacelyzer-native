#!/usr/bin/env python3
"""Execute real capture binding, artifact verifier and proposed observed gate.
Synthetic AX/image seams only. Not a Mac export, visual or SwiftUI proof.
"""
import importlib.util,pathlib,tempfile,json,subprocess,copy,sys
spec=importlib.util.spec_from_file_location('gate','scripts/check-observed-demo-state.py');g=importlib.util.module_from_spec(spec);spec.loader.exec_module(g)
m=g.binding
TEXT=['Not scanned','These locations were not scanned, so they are not in the totals.']

def fixture(p):
 token='fresh-unique-capture-token';pin=dict(pid=42,start='start-A',executable='/app/A',source='sha-A')
 root=p/'out'/token;root.mkdir(parents=True);(p/'images').mkdir()
 raw=p/'spz-demo-state-78';ready=p/'spz-demo-ready-78'
 raw.write_text(f'step=78 captureToken={token} pid=42 source=sha-A main=true w=960 h=600 sheet=true keyIsSheet=true alertModel=false sheetRows=1 sheetId=unknown')
 ready.write_text(token);(p/'pin').write_text(json.dumps(pin));(p/'out'/'launch-pin.json').write_text(json.dumps(pin));(root/'process-pin.json').write_text(json.dumps(pin))
 (root/'producer-ready.txt').write_text(token);(root/'raw-native.txt').write_bytes(raw.read_bytes())
 anchor=dict(pin,step=78,token=token,raw_sha256=m.digest(raw));(root/'ready.json').write_text(json.dumps(anchor));expected=dict(anchor);expected.pop('raw_sha256')
 m.capture(ready=root/'ready.json',raw=raw,ack=p/'ack',expected=expected,output=root/'bound',inspect=lambda _:dict(pid=42,start='start-A',executable='/app/A'),source=lambda:'sha-A',observe=lambda _:dict(source='external-AXUIElement',pid=42,step=78,captureToken=token,identity='notscanned',rows=1,complete=True,reason='observed',scopeCount=1,texts=TEXT),screenshot=lambda path:path.write_bytes(b'fake-image-bytes'))
 (p/'images'/'screenshot-demo-78.png').write_bytes((root/'bound'/'capture.png').read_bytes())
 (p/'out'/'attempt-abc').mkdir();(p/'out'/'attempt-abc'/'supervisor.json').write_text(json.dumps(dict(status='complete',returncode=0,budgetSeconds=18,acceptance=False)))
 return root,root/'bound'

def execute(p):return g.check(p,78,78,p/'out',p/'pin','sha-A','/app/A',p/'images')
def edit(path,fn):
 d=json.loads(path.read_text());fn(d);path.write_text(json.dumps(d))
def resign(b):
 edit(b/'binding.json',lambda d:d.update(raw_sha256=m.digest(b/'raw-native.txt'),external_sha256=m.digest(b/'external.json'),image_sha256=m.digest(b/'capture.png')))
scenarios=['good','native-positive','native-missing','missing-raw','missing-ready','missing-pin','missing-image','missing-manifest','missing-external','tamper-raw','tamper-image','tamper-external','summary','pid','start','executable','source','token','step','replay','supervisor-timeout','supervisor-failed','supervisor-missing','prepost-missing','prepost-extra','hash-both-images','post-pid','post-source','post-raw','post-ready','post-ack','post-order','post-late','text','qualifier','rows','scope','reason','complete','identity','conflict','external-token','external-pid','external-step','canonical-image','native-no-sheet','native-key','native-alert','native-rows','native-size','path-token','pin-copy','producer-copy']
for scenario in scenarios:
 with tempfile.TemporaryDirectory() as t:
  p=pathlib.Path(t);root,b=fixture(p);raw=p/'spz-demo-state-78';manifest=b/'binding.json';external=b/'external.json'
  if scenario.startswith('missing-'):
   {'raw':raw,'ready':p/'spz-demo-ready-78','pin':p/'pin','image':b/'capture.png','manifest':manifest,'external':external}[scenario[8:]].unlink()
  elif scenario in ['tamper-raw','tamper-image','tamper-external']:(b/{'tamper-raw':'raw-native.txt','tamper-image':'capture.png','tamper-external':'external.json'}[scenario]).write_bytes(b'tampered')
  elif scenario=='summary':edit(manifest,lambda d:d['reconciliation'].update(nativeAccessorPassed=True))
  elif scenario in ['pid','start','executable','source']:edit(p/'pin',lambda d:d.update({scenario:99 if scenario=='pid' else 'wrong'}))
  elif scenario=='token':(p/'spz-demo-ready-78').write_text('different-unique-token')
  elif scenario=='step':raw.write_text(raw.read_text().replace('step=78','step=77'))
  elif scenario=='replay':
   (p/'out'/'attempt-replay').mkdir();(p/'out'/'attempt-replay'/'supervisor.json').write_text('{}')
  elif scenario in ['supervisor-timeout','supervisor-failed']:edit(p/'out'/'attempt-abc'/'supervisor.json',lambda d:d.update(status=scenario.split('-')[1]))
  elif scenario=='supervisor-missing':(p/'out'/'attempt-abc'/'supervisor.json').unlink()
  elif scenario=='prepost-missing':edit(manifest,lambda d:d.update(observations=[]))
  elif scenario=='prepost-extra':edit(manifest,lambda d:d['observations'].append(copy.deepcopy(d['observations'][-1])))
  elif scenario=='hash-both-images':
   (b/'capture.png').write_bytes(b'tampered both');(p/'images'/'screenshot-demo-78.png').write_bytes(b'tampered both')
  elif scenario.startswith('post-'):
   def change(d):
    o=d['observations'][-1];kind=scenario[5:]
    if kind=='pid':o['process']['pid']=99
    elif kind=='source':o['source']='wrong'
    elif kind=='raw':o['raw_sha256']='wrong'
    elif kind=='ready':o['ready_sha256']='wrong'
    elif kind=='ack':o['ack']=True
    elif kind=='order':o['monotonic']=0
    elif kind=='late':o['monotonic']=d['observations'][0]['monotonic']+19
   edit(manifest,change)
  elif scenario in ['text','qualifier','rows','scope','reason','complete','identity','conflict','external-token','external-pid','external-step']:
   def change(d):
    if scenario=='text':d['texts']=['Not scanned elsewhere',TEXT[1]]
    elif scenario=='qualifier':d['texts']=[TEXT[0]]
    elif scenario=='conflict':d['texts']+=["Moved Backup.zip to the Trash."]
    else:
     key={'scope':'scopeCount','external-token':'captureToken','external-pid':'pid','external-step':'step'}.get(scenario,scenario)
     d[key]={'rows':0,'scope':2,'reason':'cap','complete':False,'identity':'wrong','external-token':'other-token','external-pid':43,'external-step':77}[scenario]
   edit(external,change);resign(b) # even correctly rehashed bad observation must refuse
  elif scenario=='canonical-image':(p/'images'/'screenshot-demo-78.png').write_bytes(b'unrelated normal screenshot')
  elif scenario.startswith('native-'):
   change={'native-positive':('sheetId=unknown','sheetId=removal-result'),'native-missing':('sheetId=unknown',''),'native-no-sheet':('sheet=true','sheet=false'),'native-key':('keyIsSheet=true','keyIsSheet=false'),'native-alert':('alertModel=false','alertModel=true'),'native-rows':('sheetRows=1','sheetRows=0'),'native-size':('w=960','w=20')}[scenario]
   raw.write_text(raw.read_text().replace(*change))
   # Preserve internally consistent records so refusal is about native semantics,
   # not merely noticing a stale copy/hash.
   for dest in [root/'raw-native.txt',b/'raw-native.txt']:dest.write_bytes(raw.read_bytes())
   edit(root/'ready.json',lambda d:d.update(raw_sha256=m.digest(raw)))
   def upd(d):
    d['anchor']['raw_sha256']=m.digest(raw)
    for o in d['observations']:o.update(raw_sha256=m.digest(raw),ready_sha256=m.digest(root/'ready.json'))
   edit(manifest,upd);resign(b)
  elif scenario=='path-token':(p/'spz-demo-ready-78').write_text('../unsafe-token-name')
  elif scenario=='pin-copy':edit(root/'process-pin.json',lambda d:d.update(start='wrong'))
  elif scenario=='producer-copy':(root/'producer-ready.txt').write_text('wrong')
  failures,routes=execute(p)
  assert bool(failures)==(scenario!='good'),(scenario,failures)
  if scenario=='good':
   assert routes[0]['criterion']=='observed-sheet-v1' and routes[0]['nativeAccessorPassed'] is False
   assert g.native.check(p,78,78) # unchanged native criterion still fails
   assert 'sheetId=unknown' in raw.read_text()
  print('PASS actual observed gate',scenario)
# Native agreement still requires a bound witness under the new explicit rule.
with tempfile.TemporaryDirectory() as t:
 p=pathlib.Path(t);root,b=fixture(p);r=p/'spz-demo-state-78';r.write_text(r.read_text().replace('sheetId=unknown','sheetId=notscanned'))
 for dest in [root/'raw-native.txt',b/'raw-native.txt']:dest.write_bytes(r.read_bytes())
 edit(root/'ready.json',lambda d:d.update(raw_sha256=m.digest(r)))
 def upd(d):
  d['anchor']['raw_sha256']=m.digest(r);d['reconciliation'].update(nativeIdentity='notscanned',nativeAccessorPassed=True)
  for o in d['observations']:o.update(raw_sha256=m.digest(r),ready_sha256=m.digest(root/'ready.json'))
 edit(b/'binding.json',upd);resign(b)
 bad,routes=execute(p);assert not bad and routes[0]['nativeAccessorPassed'] is True and not g.native.check(p,78,78)
 print('PASS native agreement requires same bound external observed criterion')
 edit(b/'external.json',lambda d:d.update(identity='removal-result'));resign(b)
 assert execute(p)[0]
 print('PASS positive native/external disagreement refused')
# Test-only mutation: disabling content validation must let a rehashed hostile
# case through, so the assertion that it is rejected fails. Proves check matters.
with tempfile.TemporaryDirectory() as t:
 p=pathlib.Path(t);root,b=fixture(p);edit(b/'external.json',lambda d:d.update(texts=['background']));resign(b)
 assert execute(p)[0]
 original=m.validate_probe;m.validate_probe=lambda _:None
 try:assert not execute(p)[0]
 finally:m.validate_probe=original
 print('PASS nonvacuity: disabling actual probe-content check accepts hostile bytes (negative assertion would fail)')
