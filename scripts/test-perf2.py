#!/usr/bin/env python3
"""Controls for the stability and cancel measurement scripts (scripts/perf2-*). Fakes only: nothing here is a Mac result. Every check has a failing counterpart (mutation)."""
import os, pathlib, subprocess, sys, tempfile, time, yaml, json, stat, shutil
R = pathlib.Path(__file__).resolve().parent.parent; S = R / 'scripts'; T = pathlib.Path(tempfile.mkdtemp(prefix='perf2test-'))
n = 0
def ok(c, m):
    global n
    assert c, m; n += 1
def sh(*a, env=None, **k): return subprocess.run(list(map(str, a)), capture_output=True, text=True, env=env, **k)
def verdict(d): return (pathlib.Path(d) / 'verdict.txt').read_text().split('\n')[0]
E = lambda **kw: dict(os.environ, **{k: str(v) for k, v in kw.items()})
# --- soak plateau
def fake_spz(path, leak):
    path.write_text('#!/usr/bin/env python3\nimport sys,time\nkeep=[bytearray(30*1024*1024)]\nfor i in range(len(keep[0])//4096): keep[0][i*4096]=1\nfor i in range(int(sys.argv[3])):\n' +
        ('    keep.append(bytearray(3*1024*1024)); k=keep[-1]\n    for j in range(0,len(k),4096): k[j]=1\n' if leak else '') + '    time.sleep(0.1); print(f"run {i+1}: 1 items 0.1s (peak rss 1.0 MB)",flush=True)\n'); path.chmod(0o755)
fs, fl = T / 'steady.py', T / 'leak.py'; fake_spz(fs, False); fake_spz(fl, True)
for f, want in ((fs, 'PASS'), (fl, 'FAIL')):
    o = T / ('soak-' + f.stem); sh(sys.executable, S / 'perf2-soak.py', '--spz', f, '--root', T, '--reps', 30, '--window', 10, '--out', o)
    ok((o / 'soak-verdict.txt').read_text().split('\n')[0] == want, f'soak {f.stem} must be {want}: ' + (o / 'soak-verdict.txt').read_text())
o = T / 'soak-short'; sh(sys.executable, S / 'perf2-soak.py', '--spz', fs, '--root', T, '--reps', 5, '--window', 10, '--out', o); ok((o / 'soak-verdict.txt').read_text().startswith('INCOMPLETE'), 'too few scans is INCOMPLETE')
# --- cancel verdict
def cv(result, perf, runs=3):
    d = T / f'c{len(list(T.glob("c*")))}'; d.mkdir()
    if result is not None: (d / 'result.txt').write_text(result)
    if perf is not None: (d / 'perf.txt').write_text(perf)
    sh(sys.executable, S / 'perf2-cancel-verdict.py', d, d / 'out.txt', runs); return (d / 'out.txt').read_text().split('\n')[0]
line = lambda i, items: f'cancel[{i}] items_at_cancel={items} cancel_call_ms=0.1 cancel_to_engine_returned_ms=40.0 cancel_to_scanning_false_ms=45.0 tree_present_after_cancel=false error=none\n'
good = line(1, 20000) + line(2, 21000) + line(3, 30000) + 'full_scan nodes=202001 progress_items=202001 last_scan_seconds=0.9\n'
ok(cv('PERF-COMPLETE\n', good) == 'PASS', 'complete mid-scan cancels PASS')
ok(cv(None, None) == 'INCONCLUSIVE', 'no result is INCONCLUSIVE')
ok(cv('PERF-INCOMPLETE\nx\n', good) == 'INCONCLUSIVE', 'driver incomplete is INCONCLUSIVE')
ok(cv('PERF-COMPLETE\n', line(1, 20000) + line(2, 21000) + line(3, 30000).replace('scanning_false_ms=45.0', 'scanning_false_ms=900.0') + 'full_scan nodes=202001 progress_items=202001 last_scan_seconds=0.9\n') == 'INCONCLUSIVE', 'a cancel that lands at ~full scan duration must not pass')
ok(cv('PERF-COMPLETE\n', good.replace('last_scan_seconds=0.9', '')) == 'INCONCLUSIVE', 'missing scan duration is INCONCLUSIVE')
ok(cv('PERF-COMPLETE\n', line(1, 20000) + line(2, 21000) + 'full_scan nodes=202001\n') == 'INCONCLUSIVE', 'two of three samples is INCONCLUSIVE')
ok(cv('PERF-COMPLETE\n', line(1, 20000) + line(2, 21000) + line(3, 202001) + 'full_scan nodes=202001\n') == 'INCONCLUSIVE', 'cancel at the end of the tree is not proven mid-scan')
ok(cv('PERF-COMPLETE\n', line(1, 20000) + line(2, 21000) + line(3, 30000)) == 'INCONCLUSIVE', 'missing full-scan node count is INCONCLUSIVE')
# --- stability script with fakes (bash only; no Mac)
F = T / 'fake'; F.mkdir(); shutil.copy('/bin/sleep', F / 'Spacelyzer')
(F / 'open').write_text('#!/bin/bash\n' + str(F) + '/Spacelyzer 600 & disown\n')
(F / 'bench').write_text('#!/bin/bash\necho \'{}\' > "$3"; exit ${FAKE_BENCH_RC:-0}\n'); (F / 'ready').write_text('#!/bin/bash\nexit ${FAKE_READY_RC:-0}\n')
for f in ('open', 'bench', 'ready'): (F / f).chmod(0o755)
(T / 'fx' / 'typing' / 'typing-200k').mkdir(parents=True); (T / 'fx' / 'exp').mkdir()
def stab(name, **env):
    o = T / name; e = E(PATH=f'{F}:' + os.environ['PATH'], **env)
    sh('bash', S / 'perf2-stability.sh', 'x', fs, T / 'fx', o, S, F / 'bench', F / 'ready', env=e); return (o / 'verdict.txt').read_text()
subprocess.run(['pkill', '-x', 'Spacelyzer'])
v = stab('st1', FAKE_SOAK='1'); ok('expansion-10k PASS' in v and 'typing-200k PASS' in v and 'hover PASS' in v and 'app-alive PASS' in v, 'stability fake parts pass: ' + v)
v = stab('st2', FAKE_BENCH_RC=10); ok(v.startswith('FAIL') and 'typing-200k FAIL' in v, 'bench failure makes the leg FAIL')
v = stab('st3', FAKE_READY_RC=3); ok(v.split('\n')[0] in ('INCOMPLETE', 'FAIL') and 'typing-200k INCOMPLETE' in v, 'readiness failure is INCOMPLETE, not PASS')
subprocess.run(['pkill', '-x', 'Spacelyzer'])
# required-parts aggregation: removed and duplicated part lines (simulate by wrapping the part writer)
def stab_mut(name, sedexpr):
    o = T / name; sc = T / (name + '.sh'); sc.write_text(subprocess.run(['sed', sedexpr, str(S / 'perf2-stability.sh')], capture_output=True, text=True).stdout)
    sh('bash', sc, 'x', fs, T / 'fx', o, S, F / 'bench', F / 'ready', env=E(PATH=f'{F}:' + os.environ['PATH'])); return (o / 'verdict.txt').read_text()
v = stab_mut('st4', 's|^part() { echo "$1 $2 $3" >> "$OUT/parts.txt";|part() { [ "$1" = hover ] \&\& return; echo "$1 $2 $3" >> "$OUT/parts.txt";|'); ok(v.split('\n')[0] != 'PASS' and 'hover(x0)' in v, 'a removed part line must not PASS: ' + v)
v = stab_mut('st5', 's|^part() { echo "$1 $2 $3" >> "$OUT/parts.txt";|part() { echo "$1 $2 $3" >> "$OUT/parts.txt"; [ "$1" = hover ] \&\& echo "$1 $2 $3" >> "$OUT/parts.txt";|'); ok(v.split('\n')[0] != 'PASS' and 'hover(x2)' in v, 'a duplicated part line must not PASS: ' + v)
subprocess.run(['pkill', '-x', 'Spacelyzer'])
# helper wiring
ok('perf2-soak.py' in (S / 'perf2-stability.sh').read_text() and 'perf2-cancel-verdict.py' in (S / 'perf2-cancel.sh').read_text(), 'helpers wired')
shutil.rmtree(T, ignore_errors=True); print(f'PASS {n} checks (fakes only, not a Mac result)')
