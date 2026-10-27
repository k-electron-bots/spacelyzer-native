#!/usr/bin/env python3
"""Controls for scripts/perf2-typing.sh (fakes only, not a Mac result)."""
import os, pathlib, re, shutil, subprocess, tempfile, yaml
R = pathlib.Path(__file__).resolve().parent.parent; S = R / 'scripts'; T = pathlib.Path(tempfile.mkdtemp()); n = 0
def ok(c, m):
    global n; assert c, m; n += 1
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
shutil.rmtree(T, ignore_errors=True); print(f'PASS {n} typing-script checks (fakes only, not a Mac result)')
