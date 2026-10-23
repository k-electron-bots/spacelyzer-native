#!/usr/bin/env python3
"""Executed Linux controls for ordering admission/result gate. Not Mac execution."""
import importlib.util, pathlib, tempfile, subprocess, sys
spec=importlib.util.spec_from_file_location('ordering',pathlib.Path(__file__).with_name('run-demo-ordering.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
assert m.admission(1000,310)==640
for now in [310.01,999,1001]:
    try:m.admission(1000,now)
    except RuntimeError:pass
    else:raise AssertionError('late admission accepted')
with tempfile.TemporaryDirectory() as t:
    p=pathlib.Path(t)
    (p/'result.txt').write_text('PASS 2 required checks, each exactly once\n')
    (p/'assertions.txt').write_text('PASS one detail\nPASS two detail\n')
    m.verify_result(p,['one','two'])
    for text in ['PASS one\n','PASS one\nPASS one\n','PASS one\nFAIL two\n','PASS one\nPASS other\n']:
        (p/'assertions.txt').write_text(text)
        try:m.verify_result(p,['one','two'])
        except RuntimeError:pass
        else:raise AssertionError('bad results accepted')
    # Admission refusal must produce durable failure without needing any Mac binary.
    r=subprocess.run([sys.executable,str(pathlib.Path(__file__).with_name('run-demo-ordering.py')),'--app','missing','--output',str(p/'out'),'--job-deadline','1'])
    assert r.returncode==1 and 'INCOMPLETE' in (p/'out/segment-verdict.txt').read_text()
print('PASS admission boundary690, late/expired refusal, exact-name negatives, durable refused artifact')
# Exercise setup/timeout/nonzero-exit/partial evidence paths with subprocess seams,
# leaving filesystem copying and result retention real. Never a native-app claim.
import os, plistlib
from unittest.mock import patch
class Child:
    pid=99999999
    def __init__(self,*a,**kw): self.mode=MODE; self.calls=0; kw['stderr'].write('retained diagnostic\n'); kw['stderr'].flush()
    def wait(self,timeout=None):
        self.calls+=1
        if self.mode=='timeout' and self.calls==1: raise subprocess.TimeoutExpired('fake-app',timeout)
        return 7 if self.mode=='failure' else 0
for MODE in ['timeout','failure','missing-result']:
    with tempfile.TemporaryDirectory() as t:
        p=pathlib.Path(t);app=p/'app';(app/'Contents/MacOS').mkdir(parents=True)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'original'}))
        (app/'Contents/MacOS/Spacelyzer').write_text('fixture only')
        with patch.object(m.subprocess,'run',return_value=subprocess.CompletedProcess([],0)),patch.object(m,'stop_apps'),patch.object(m.subprocess,'Popen',Child),patch('os.killpg'):
            try:m.run(str(app),str(p/'output'),m.time.time()+1000)
            except (RuntimeError,subprocess.TimeoutExpired,FileNotFoundError):pass
            else:raise AssertionError('broken child accepted')
        assert (p/'output/stderr.log').read_text()=='retained diagnostic\n'
        assert (p/'output/results').is_dir()
print('PASS timeout, nonzero child exit, missing result all retain partial artifacts')
# Wiring: prior evidence uploaded first, ordering required even when refused/skipped,
# and ordering's own artifact always attempted with a bounded upload budget.
import yaml
workflow=yaml.safe_load(pathlib.Path('.github/workflows/demo-only.yml').read_text())
steps=workflow['jobs']['macos']['steps'];ids={x.get('id'):x for x in steps}
order=[x.get('id') for x in steps]
assert order.index('demo_artifact')<order.index('ordering')<order.index('ordering_artifact')
assert ids['ordering_artifact']['if']=='${{ always() }}' and ids['ordering_artifact']['timeout-minutes']==2
assert workflow['jobs']['macos']['timeout-minutes']==35
assert 'SPZ_JOB_DEADLINE_EPOCH - 1380' in pathlib.Path('.github/workflows/demo-only.yml').read_text()
print('PASS early artifact ordering, always bounded ordering artifact, unchanged720compile/2100job')
