#!/usr/bin/env python3
"""Controls for .github/workflows/perf-followup.yml and scripts/perf2-typing.sh (fakes only, not a Mac result)."""
import os, pathlib, re, shutil, subprocess, tempfile, yaml
R = pathlib.Path(__file__).resolve().parent.parent; S = R / 'scripts'; T = pathlib.Path(tempfile.mkdtemp()); n = 0
def ok(c, m):
    global n; assert c, m; n += 1
txt = (R / '.github/workflows/perf-followup.yml').read_text(); wf = yaml.safe_load(txt); on = wf.get(True, wf.get('on'))
ok(list(on) == ['workflow_dispatch'] and not on['workflow_dispatch'] and wf['permissions'] == {'contents': 'read'}, 'dispatch only, read-only')
code = '\n'.join(l for l in txt.split('\n') if not l.strip().startswith('#'))
for bad in ('gh release', 'releases/', 'git tag', 'git push', 'notarytool', 'contents: write', 'upload-release', 'accuracy', 'stability', 'expansion'): ok(bad not in code, f'no {bad}')
ship = yaml.safe_load((R / '.github/workflows/ship-candidate.yml').read_text()); ok(wf['jobs']['identity-guard'] == ship['jobs']['identity-guard'], 'guard identical')
mac = wf['jobs']['macos']; st = mac['steps']; ids = {x.get('id'): x for x in st if x.get('id')}; order = [x.get('id') for x in st]
ok(mac['timeout-minutes'] == 35 and '2100' in st[0]['run'], '35 min clock')
chain = ['engine', 'swiftapp', 'sign', 'pkg', 'tools', 'fixtures', 'typing', 'perfbuild', 'cancel', 'gate', 'perf_artifact']; pos = [order.index(c) for c in chain]; ok(pos == sorted(pos), 'order typing then cancel')
for l in ('typing', 'cancel'):
    s = ids[l]; ok(s.get('continue-on-error') is True and 'perf2-leg.py --leg ' + l in s['run'] and '--prereq' in s['run'], f'{l} isolated')
ok('perf2-typing.sh' in ids['typing']['run'] and 'perf2-cancel.sh' in ids['cancel']['run'] and 'typing,cancel' in txt and order.index('gate') < order.index('perf_artifact'), 'wiring')
# typing script with fakes
F = T / 'fake'; F.mkdir(); shutil.copy('/bin/sleep', F / 'Spacelyzer')
(F / 'open').write_text('#!/bin/bash\n' + str(F) + '/Spacelyzer 600 & disown\n'); (F / 'bench').write_text('#!/bin/bash\necho "{}" > "$3"; exit ${FAKE_BENCH_RC:-0}\n'); (F / 'ready').write_text('#!/bin/bash\nexit ${FAKE_READY_RC:-0}\n')
for f in ('open', 'bench', 'ready'): (F / f).chmod(0o755)
def typ(name, **env):
    o = T / name; subprocess.run(['pkill', '-x', 'Spacelyzer'])
    subprocess.run(['bash', S / 'perf2-typing.sh', 'x', T / 'fx', o, S, F / 'bench', F / 'ready'], env=dict(os.environ, PATH=f'{F}:' + os.environ['PATH'], **{k: str(x) for k, x in env.items()}), capture_output=True)
    subprocess.run(['pkill', '-x', 'Spacelyzer']); return (o / 'verdict.txt').read_text()
v = typ('t1'); ok(v.startswith('PASS') and 'typing-200k PASS' in v and 'app-alive PASS' in v, 'typing passes: ' + v)
v = typ('t2', FAKE_BENCH_RC=7); ok(v.startswith('FAIL') and 'bench exit 7' in v, 'bench exit 7 is FAIL: ' + v)
v = typ('t3', FAKE_READY_RC=3); ok(v.startswith('INCOMPLETE'), 'readiness failure is INCOMPLETE: ' + v)
shutil.rmtree(T, ignore_errors=True); print(f'PASS {n} follow-up checks (fakes only, not a Mac result)')
