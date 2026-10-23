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
# Fake only native commands/clock. Fresh filesystem and partial retention remain real.
for mode in ['launch-failure','crash','timeout','failed-result','missing-result']:
    with tempfile.TemporaryDirectory() as t:
        p=pathlib.Path(t);app=p/'app';(app/'Contents/MacOS').mkdir(parents=True)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'original'}))
        (app/'Contents/MacOS/Spacelyzer').write_text('fixture only')
        clock=[1000.0]
        def native(argv, **kwargs):
            if argv[0]=='open':
                pathlib.Path(argv[argv.index('--stderr')+1]).write_text('retained diagnostic\n')
                if mode=='launch-failure': raise subprocess.CalledProcessError(1,argv)
                result=next(x.split('=',1)[1] for x in argv if x.startswith('SPZ_RESULT_DIR='))
                if mode=='failed-result':
                    pathlib.Path(result,'result.txt').write_text('FAIL simulated crash/check failure\n')
                if mode=='crash': clock[0]+=400
            return subprocess.CompletedProcess(argv,0)
        def sleep(seconds): clock[0]+=max(seconds,.2)
        with patch.object(m.subprocess,'run',side_effect=native),patch.object(m,'stop_apps'),patch.object(m.time,'time',side_effect=lambda:clock[0]),patch.object(m.time,'sleep',side_effect=sleep):
            try:m.run(str(app),str(p/'output'),2000)
            except (RuntimeError,subprocess.CalledProcessError,FileNotFoundError):pass
            else:raise AssertionError('broken launch accepted')
        assert (p/'output/stderr.log').read_text()=='retained diagnostic\n'
        assert (p/'output/results').is_dir()
print('PASS fake-open launch failure, crash, timeout, failed/missing result retain partial artifacts')
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
