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
 assert 'scripts/run-bounded.py 18 python3 scripts/capture-sheet-evidence.py capture' in w
 assert 'SPZ_CAPTURE_SOURCE="$(git rev-parse HEAD)"' in w
 assert 'scripts/capture-sheet-evidence.py pin' in w
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
    if scenario=='orchestrated-timeout':raise m.subprocess.TimeoutExpired(argv,8)
    return type('R',(),{'returncode':0,'stderr':'','stdout':json.dumps(dict(pid=42,step=78,captureToken=token,source='external-AXUIElement',identity='notscanned',rows=1,complete=True))})()
   if argv[0]=='screencapture':pathlib.Path(argv[-1]).write_bytes(b'png');return None
   raise AssertionError(argv)
  original=m.subprocess.run;m.subprocess.run=run
  try:
   if scenario=='orchestrated-timeout':
    try:m.diagnostic_step78(p/'pin',raw,ready,ack,p/'out')
    except m.subprocess.TimeoutExpired:print('PASS actual orchestration timeout refusal')
    else:raise AssertionError('timeout accepted')
   else:
    result=m.diagnostic_step78(p/'pin',raw,ready,ack,p/'out');assert result['reconciliation']['nativeIdentity']=='unknown'
    if scenario=='orchestrated-replay':
     try:m.diagnostic_step78(p/'pin',raw,ready,ack,p/'out')
     except ValueError:print('PASS actual orchestration token replay refusal')
     else:raise AssertionError('replay accepted')
    else:print('PASS actual diagnostic orchestration produces separately bound image/manifest')
  finally:m.subprocess.run=original
