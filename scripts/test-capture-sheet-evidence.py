#!/usr/bin/env python3
import importlib.util,pathlib,tempfile,json,hashlib
spec=importlib.util.spec_from_file_location('binding','scripts/capture-sheet-evidence.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
for scenario in ['good','step','token','source','pid','start','executable','rawhash','ack','probe-token','timeout','native-disagreement','unreadable','raw-after-probe','raw-after-shot','process-after-shot']:
 with tempfile.TemporaryDirectory() as t:
  p=pathlib.Path(t);raw=p/'raw';ready=p/'ready';ack=p/'ack';token='fresh-unique-capture-token'
  raw.write_text('step=78 captureToken='+token+' pid=42 main=true sheet=true keyIsSheet=true alertModel=false sheetRows=1 sheetId='+('removal-result' if scenario=='native-disagreement' else 'unknown'))
  anchor=dict(step=78,token=token,pid=42,start='start-A',executable='/app/A',source='sha-A',raw_sha256=m.digest(raw));ready.write_text(json.dumps(anchor));expected=dict(anchor);expected.pop('raw_sha256')
  if scenario in ['step','pid']:expected[scenario]+=1
  if scenario in ['token','source','start','executable']:expected[scenario]+='wrong'
  if scenario=='rawhash':raw.write_text('changed')
  if scenario=='ack':ack.touch()
  shot=[False]
  def inspect(pid):return dict(pid=42,start='changed' if scenario=='process-after-shot' and shot[0] else 'start-A',executable='/app/A')
  def observe(a):
   if scenario=='timeout':raise TimeoutError('bounded external probe timed out')
   if scenario=='raw-after-probe':raw.write_text('changed')
   return dict(pid=42,step=78,captureToken=token+'wrong' if scenario=='probe-token' else token,source='external-AXUIElement',identity='notscanned',rows=1,complete=scenario!='unreadable')
  def screenshot(path):
   path.write_bytes(b'png');shot[0]=True
   if scenario=='raw-after-shot':raw.write_text('changed')
  try:r=m.capture(ready=ready,raw=raw,ack=ack,expected=expected,output=p/'out',inspect=inspect,observe=observe,screenshot=screenshot,source=lambda:'sha-A')
  except (ValueError,TimeoutError):assert scenario!='good',scenario;print('PASS refusal',scenario)
  else:assert scenario=='good',scenario;assert r['reconciliation']['nativeIdentity']=='unknown' and not r['reconciliation']['nativeAccessorPassed'];print('PASS bound diagnostic preserves native unknown')

# Source-level workflow/producer wiring controls, not Mac execution.
s=pathlib.Path('Sources/Spacelyzer/SpacelyzerApp.swift').read_text()
assert 'let captureToken = UUID().uuidString' in s
assert 'captureToken=\\(captureToken)' in s and 'source=\\(captureSource)' in s
for f in ['.github/workflows/demo-only.yml','.github/workflows/ci.yml']:
 w=pathlib.Path(f).read_text()
 assert 'python3 scripts/capture-sheet-evidence.py capture' in w
 assert 'dist/sheet-observation/' in w
 assert 'capture_pid=$(pgrep' not in w
 assert 'SPZ_CAPTURE_SOURCE="$(git rev-parse HEAD)"' in w
 assert 'scripts/capture-sheet-evidence.py wait-pin' in w
 assert 'EXTERNAL SHEET DIAGNOSTIC INCOMPLETE (not acceptance)' in w
assert 'check-demo-state.py /tmp 81' in pathlib.Path('.github/workflows/demo-only.yml').read_text()
print('PASS diagnostic producer/workflow wiring; original fidelity gate remains unchanged')
# Execute the actual orchestration function with declared ps/git/helper/screenshot
# subprocess seams. Proves pin->producer-ready->probe->image->manifest and replay
# refusal, not macOS ps output or AX runtime.
for scenario in ['orchestrated-good','orchestrated-timeout','orchestrated-replay']:
 with tempfile.TemporaryDirectory() as t:
  p=pathlib.Path(t);token='producer-generated-uuid-A';raw=p/'raw';ready=p/'ready';ack=p/'ack'
  raw.write_text(f'step=78 pid=42 captureToken={token} source=sha-A main=true sheet=true keyIsSheet=true alertModel=false sheetRows=1 sheetId=unknown')
  ready.write_text(token);pin=dict(pid=42,start='start-A',executable='/app/A',source='sha-A');(p/'pin').write_text(json.dumps(pin))
  def run(argv,**kw):
   if argv[0]=='ps':return type('R',(),{'stdout':'start-A' if argv[-1]=='lstart=' else '/app/A'})()
   if argv[0]=='git':return type('R',(),{'stdout':'sha-A'})()
   if argv[0]=='/tmp/spz-sheet-probe':
    assert kw['timeout']==8
    if scenario=='orchestrated-timeout':raise m.subprocess.TimeoutExpired(argv,8,output=b'partial probe',stderr=b'partial error')
    return type('R',(),{'returncode':0,'stderr':'','stdout':json.dumps(dict(pid=42,step=78,captureToken=token,source='external-AXUIElement',identity='notscanned',rows=1,complete=True))})()
   if argv[0]=='screencapture':pathlib.Path(argv[-1]).write_bytes(b'png');return None
   raise AssertionError(argv)
  original=m.subprocess.run;m.subprocess.run=run
  try:
   if scenario=='orchestrated-timeout':
    try:m.diagnostic_step78(p/'pin',raw,ready,ack,p/'out')
    except m.subprocess.TimeoutExpired:
     assert (p/'out'/token/'probe-stdout.txt').read_text()=='partial probe'
     assert (p/'out'/token/'raw-native.txt').read_bytes()==raw.read_bytes()
     print('PASS actual orchestration timeout refusal with partial probe/raw retained')
    else:raise AssertionError('timeout accepted')
   else:
    result=m.diagnostic_step78(p/'pin',raw,ready,ack,p/'out');assert result['reconciliation']['nativeIdentity']=='unknown'
    if scenario=='orchestrated-replay':
     try:m.diagnostic_step78(p/'pin',raw,ready,ack,p/'out')
     except ValueError:print('PASS actual orchestration token replay refusal')
     else:raise AssertionError('replay accepted')
    else:print('PASS actual diagnostic orchestration produces separately bound image/manifest')
  finally:m.subprocess.run=original
# Execute supervisor, not a source-string claim: outer timeout preserves partial
# files/status and terminates worker descendants before returning to ack flow.
import sys,os,time
for scenario in ['success','failure','timeout']:
 with tempfile.TemporaryDirectory() as t:
  p=pathlib.Path(t);partial=p/'partial.txt'
  code="import pathlib,time;pathlib.Path(%r).write_text('partial');"%str(partial)
  code+= "print('binding manifest')" if scenario=='success' else ("raise SystemExit(7)" if scenario=='failure' else 'time.sleep(10)')
  started=time.monotonic();rc=m.supervise_capture(['pin','raw','ready','ack',str(p)],budget=.2,command=[sys.executable,'-c',code])
  status=json.loads(next(p.glob('attempt-*/supervisor.json')).read_text())
  assert partial.read_text()=='partial' and time.monotonic()-started<2
  assert status['status']=={'success':'complete','failure':'failed','timeout':'timed-out'}[scenario]
  assert (rc==0)==(scenario=='success')
  if scenario=='timeout':assert 'partial artifacts retained' in status['reason']
  print('PASS actual outer supervisor',scenario)
# Executed delayed-pid discovery and bounded refusal, preserving exact reason.
for scenario in ['delayed','refusal']:
 with tempfile.TemporaryDirectory() as t:
  p=pathlib.Path(t);calls=[0]
  def run(argv,**kw):
   assert 0<kw['timeout']<=.35
   if argv[0]=='pgrep':
    calls[0]+=1
    return type('R',(),dict(returncode=1 if scenario=='refusal' or calls[0]==1 else 0,stdout='42',stderr='no matching process'))()
   return type('R',(),dict(stdout=('start-A' if argv[-1]=='lstart=' else '/app/A') if argv[0]=='ps' else 'sha-A'))()
  original=m.subprocess.run;m.subprocess.run=run
  try:
   if scenario=='delayed':
    r=m.wait_pin(p/'pin','/app/A',p/'out',budget=.35);assert r['pid']==42 and calls[0]>=2
   else:
    try:m.wait_pin(p/'pin','/app/A',p/'out',budget=.15)
    except ValueError:pass
    else:raise AssertionError('missing pin accepted')
    assert 'pgrep rc=1' in (p/'out'/'launch-pin-failure.json').read_text() and not (p/'pin').exists()
  finally:m.subprocess.run=original
  print('PASS actual launch wait',scenario)
# Artifact routing is checked on the actual upload steps, not an arbitrary path
# occurrence. The prior candidate (missing path) must fail this same predicate.
import yaml

def retained_uploads(text):
 d=yaml.safe_load(text);steps=d['jobs']['macos']['steps']
 return [s for s in steps if s.get('uses','').startswith('actions/upload-artifact@') and ('dist/chronology/' in s.get('with',{}).get('path',''))]
for f in ['.github/workflows/demo-only.yml','.github/workflows/ci.yml']:
 text=pathlib.Path(f).read_text();uploads=retained_uploads(text)
 assert uploads and all('dist/sheet-observation/' in s['with']['path'] for s in uploads)
 old=text.replace('            dist/sheet-observation/\n','')
 assert not all('dist/sheet-observation/' in s['with']['path'] for s in retained_uploads(old))
 print('PASS upload retention old-fail/new-pass',f)
# A spawned grandchild heartbeat must stop when the outer deadline kills the
# worker group. This executes real processes, not a mocked timeout exception.
with tempfile.TemporaryDirectory() as t:
 p=pathlib.Path(t);heartbeat=p/'heartbeat'
 child="import pathlib,time\np=pathlib.Path(%r)\nwhile True:\n p.write_text(str(time.monotonic()));time.sleep(.02)"%str(heartbeat)
 worker='import subprocess,sys,time;subprocess.Popen([sys.executable,"-c",%r]);time.sleep(10)'%child
 assert m.supervise_capture(['pin','raw','ready','ack',str(p)],budget=.3,command=[sys.executable,'-c',worker])==1
 assert heartbeat.exists();last=heartbeat.read_text();time.sleep(.12);assert heartbeat.read_text()==last
 print('PASS actual outer timeout kills descendants and retains partial artifacts')
