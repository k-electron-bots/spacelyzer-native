#!/usr/bin/env python3
"""Runner side of the serviced-wait handshake, executed through the real
diagnostic_step78 with declared subprocess seams. Linux logic proof only."""
import importlib.util,pathlib,tempfile,json,threading,time
spec=importlib.util.spec_from_file_location('binding','scripts/capture-sheet-evidence.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
good=lambda token:json.dumps(dict(pid=42,step=78,captureToken=token,source='external-AXUIElement',identity='notscanned',scopeCount=1,reason='observed',texts=['Not scanned','These locations were not scanned, so they are not in the totals.'],rows=1,complete=True))
for scenario in ['request-during-probe','removed-after-timeout','removed-after-refusal','drift-rejected','drift-before-probe-rejected','no-blocked-marker-refuses']:
 with tempfile.TemporaryDirectory() as t:
  p=pathlib.Path(t);token='producer-generated-uuid-A';raw=p/'raw';ready=p/'ready';ack=p/'spz-demo-ack-78';req=p/'spz-demo-probe-78';drift=p/'spz-demo-drift-78'
  raw.write_text(f'step=78 pid=42 captureToken={token} source=sha-A main=true sheet=true keyIsSheet=true alertModel=false sheetRows=1 sheetId=unknown')
  ready.write_text(token);(p/'pin').write_text(json.dumps(dict(pid=42,start='start-A',executable='/app/A',source='sha-A')))
  if scenario=='drift-before-probe-rejected':drift.write_text('baseline=a')
  seen=[];blocked=p/'spz-demo-blocked-78';m.BLOCKED_WAIT_SECONDS=0.4
  stop=[False]
  def app():
   # fake app: confirms the blocked wait only after the request file is withdrawn
   while not stop[0]:
    if seen and not req.exists() and scenario!='no-blocked-marker-refuses':blocked.write_text('stable');return
    time.sleep(0.01)
  th=threading.Thread(target=app);th.start()
  def run(argv,**kw):
   if argv[0]=='ps':return type('R',(),{'stdout':'start-A' if argv[-1]=='lstart=' else '/app/A'})()
   if argv[0]=='git':return type('R',(),{'stdout':'sha-A'})()
   if argv[0]=='/tmp/spz-sheet-probe':
    seen.append(req.exists() and req.read_text()==token)
    if scenario=='removed-after-timeout':raise m.subprocess.TimeoutExpired(argv,8)
    if scenario=='drift-rejected':drift.write_text('baseline=a current=b')
    rc=1 if scenario=='removed-after-refusal' else 0
    return type('R',(),{'returncode':rc,'stderr':'','stdout':good(token)})()
   if argv[0]=='screencapture':pathlib.Path(argv[-1]).write_bytes(b'png');return None
   raise AssertionError(argv)
  orig=m.subprocess.run;m.subprocess.run=run
  try:
   try:m.diagnostic_step78(p/'pin',raw,ready,ack,p/'out');ok=True
   except (ValueError,m.subprocess.TimeoutExpired):ok=False
  finally:m.subprocess.run=orig;stop[0]=True;th.join()
  assert not req.exists(),(scenario,'probe request left behind')
  if scenario=='request-during-probe':assert ok and seen==[True],(ok,seen)
  elif scenario=='no-blocked-marker-refuses':assert not ok and seen==[True]
  elif scenario=='drift-before-probe-rejected':assert not ok and seen==[],(ok,seen)
  else:assert not ok,scenario
  print('PASS',scenario)
