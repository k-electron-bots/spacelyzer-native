#!/usr/bin/env python3
# Synthetic fixture for executed workflow/gate tests only. Never imported by gate.
import importlib.util,pathlib,json
spec=importlib.util.spec_from_file_location('binding',pathlib.Path(__file__).parent/'capture-sheet-evidence.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
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

if __name__=='__main__':
 import sys,shutil
 work=pathlib.Path(sys.argv[1]);states=pathlib.Path(sys.argv[2]);state=states/'spz-demo-state-78'
 original=state.read_bytes() if state.exists() else None
 import tempfile
 with tempfile.TemporaryDirectory() as t:
  p=pathlib.Path(t);root,b=fixture(p)
  shutil.rmtree(work/'dist'/'sheet-observation',ignore_errors=True)
  shutil.copytree(p/'out',work/'dist'/'sheet-observation')
  shutil.copyfile(p/'pin',states/'spz-capture-process-pin.json')
  shutil.copyfile(p/'spz-demo-ready-78',states/'spz-demo-ready-78')
  # Preserve malformed native state for refusal tests; healthy fixture state
  # gets producer identity fields used by actual bound capture.
  if original is not None:
   text=original.decode()
   healthy=all(x in text.split() for x in ['sheetId=notscanned','main=true','sheet=true','keyIsSheet=true','alertModel=false'])
   if healthy:state.write_bytes((p/'spz-demo-state-78').read_bytes())
   else:state.write_bytes(original)
  shutil.copyfile(p/'images'/'screenshot-demo-78.png',work/'dist'/'screenshot-demo-78.png')
