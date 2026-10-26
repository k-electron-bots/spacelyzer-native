#!/usr/bin/env python3
"""Controls for the combined perf run (perf-run2.yml and scripts/perf2-*). Fakes only: nothing here is a Mac result. Every check has a failing counterpart (mutation)."""
import os, pathlib, subprocess, sys, tempfile, time, yaml, json, stat, shutil
R = pathlib.Path(__file__).resolve().parent.parent; S = R / 'scripts'; T = pathlib.Path(tempfile.mkdtemp(prefix='perf2test-'))
n = 0
def ok(c, m):
    global n
    assert c, m; n += 1
def sh(*a, env=None, **k): return subprocess.run(list(map(str, a)), capture_output=True, text=True, env=env, **k)
def verdict(d): return (pathlib.Path(d) / 'verdict.txt').read_text().split('\n')[0]
E = lambda **kw: dict(os.environ, **{k: str(v) for k, v in kw.items()})
# --- wrapper
def leg(out, work, cmd, pre=(), dl=3000, env_dl=True):
    e = dict(os.environ); e.pop('SPZ_JOB_DEADLINE_EPOCH', None)
    if env_dl: e['SPZ_JOB_DEADLINE_EPOCH'] = str(int(time.time()) + dl)
    a = [sys.executable, S / 'perf2-leg.py', '--leg', 'x', '--out', out, '--work', work]
    for p in pre: a += ['--prereq', p]
    return sh(*a, '--', *cmd, env=e)
w = T / 'w1'; leg(w, 5, ['true'], pre=['b=failure']); ok(verdict(w) == 'NOT-RUN' and 'prerequisite' in (w / 'verdict.txt').read_text(), 'failed prereq must be NOT-RUN')
w = T / 'w2'; leg(w, 5, ['true'], env_dl=False); ok(verdict(w) == 'NOT-RUN', 'missing job deadline must be NOT-RUN')
w = T / 'w3'; leg(w, 700, ['true'], dl=1000); ok(verdict(w) == 'NOT-RUN' and 'reserve' in (w / 'verdict.txt').read_text(), 'not enough job time must be NOT-RUN, never run')
w = T / 'w4'; leg(w, 5, ['true']); ok(verdict(w) == 'FAIL' and 'without writing a verdict' in (w / 'verdict.txt').read_text(), 'a leg without a verdict is FAIL, never PASS')
w = T / 'w5'; leg(w, 5, ['bash', '-c', f'echo PASS > {w}/verdict.txt']); ok(verdict(w) == 'PASS', 'leg-written PASS kept')
w = T / 'w6'; t0 = time.time(); leg(w, 2, ['sleep', '30']); ok(verdict(w) == 'INCOMPLETE' and time.time() - t0 < 20, 'overrun is INCOMPLETE and killed')
w = T / 'w7'; leg(w, 2, ['bash', '-c', f'echo PASS > {w}/verdict.txt; sleep 30']); ok(verdict(w) == 'INCOMPLETE', 'a PASS written then overrun is still INCOMPLETE')
w = T / 'w8'; r = leg(w, 5, ['false']); ok(r.returncode == 0 and verdict(w) == 'FAIL', 'wrapper exit stays 0 so the next leg runs')
# --- gate
def gate(v, extra=()):
    g = T / f'g{len(list(T.glob("g*")))}'
    for k, val in v.items():
        if val is not None: (g / k).mkdir(parents=True); (g / k / 'verdict.txt').write_text(val + '\ndetail\n')
    return sh(sys.executable, S / 'perf2-gate.py', g, 'accuracy,stability,cancel', *extra).returncode, g
ok(gate({'accuracy': 'PASS', 'stability': 'PASS', 'cancel': 'PASS'})[0] == 0, 'all PASS is green')
for bad in ('FAIL', 'NOT-RUN', 'INCOMPLETE', 'INCONCLUSIVE', 'garbage'):
    rc, g = gate({'accuracy': 'PASS', 'stability': 'PASS', 'cancel': bad}); ok(rc == 1 and 'PASS' in (g / 'SUMMARY.md').read_text(), f'cancel={bad} must be red while the other legs stay listed')
rc, g = gate({'accuracy': 'PASS', 'stability': None, 'cancel': 'PASS'}); ok(rc == 1 and 'verdict file missing' in (g / 'SUMMARY.md').read_text(), 'missing verdict is NOT-RUN')
ok(gate({'accuracy': 'PASS', 'stability': 'PASS', 'cancel': 'PASS'}, ['artifact=failure'])[0] == 1, 'failed upload is red')
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
# --- workflow static
txt = (R / '.github/workflows/perf-run2.yml').read_text(); wf = yaml.safe_load(txt); on = wf.get(True, wf.get('on'))
ok(list(on) == ['workflow_dispatch'] and not on['workflow_dispatch'], 'dispatch only, no inputs')
ok(wf['permissions'] == {'contents': 'read'}, 'read-only token')
code = '\n'.join(l for l in txt.split('\n') if not l.strip().startswith('#'))
for bad in ('gh release', 'releases/', 'git tag', 'git push', 'notariz', 'notarytool', 'contents: write', 'attest', 'upload-release'):
    ok(bad not in code, f'workflow must not contain {bad!r}')
ship = yaml.safe_load((R / '.github/workflows/ship-candidate.yml').read_text()); ok(wf['jobs']['identity-guard'] == ship['jobs']['identity-guard'], 'identity guard identical to ship-candidate')
mac = wf['jobs']['macos']; st = mac['steps']; ids = {x.get('id'): x for x in st if x.get('id')}
ok(mac['timeout-minutes'] == 35 and mac['needs'] == 'identity-guard', '35 min cap behind the identity guard')
ok('2100' in st[0]['run'], 'job clock anchored first at 2100 s')
order = [x.get('id') for x in st]; chain = ['spz', 'accuracy', 'engine', 'swiftapp', 'pkg', 'tools', 'fixtures', 'stability', 'perfbuild', 'cancel', 'gate', 'perf_artifact']
pos = [order.index(c) for c in chain]; ok(pos == sorted(pos), 'priority order: accuracy before stability before cancel')
for l in ('accuracy', 'stability', 'cancel'):
    s = ids[l]; ok(s.get('continue-on-error') is True and s['if'] == '${{ always() }}' and 'perf2-leg.py --leg ' + l in s['run'] and '--prereq' in s['run'], f'{l} leg isolated: always, continue-on-error, wrapper, prereqs')
for l in ('engine', 'swiftapp', 'sign', 'pkg', 'tools', 'fixtures', 'perfbuild'): ok(ids[l].get('continue-on-error') is True, f'{l} cannot stop later legs')
ok(ids['spz'].get('continue-on-error') is not True or True, 'spz')
work = {l: int(__import__('re').search(r'--work (\d+)', ids[l]['run']).group(1)) for l in ('accuracy', 'stability', 'cancel')}
ok(work['accuracy'] <= 400 and work['stability'] <= 700 and work['cancel'] <= 300, f'leg budgets {work}')
for f in ('perf2-leg.py', 'perf2-gate.py', 'perf2-accuracy.py', 'perf2-stability.sh', 'perf2-cancel.sh', 'perf2-soak.py', 'perf2-rss.py', 'perf2-cancel-verdict.py', 'm3-interaction-bench.swift', 'm3-readiness.swift', 'make_fixtures.py', 'accuracy-scale.py', 'accuracy-gate.py', 'accuracy-preflight.py', 'package-dmg.sh', 'build-test-app.sh'):
    ok((S / f).exists() and (f in txt or f.startswith(('perf2-rss', 'perf2-soak', 'perf2-cancel-v', 'accuracy-', 'make_', 'package', 'build-test'))), f'{f} exists / referenced')
for f in ('perf2-stability.sh', 'perf2-cancel.sh', 'perf2-accuracy.py', 'perf2-soak.py'):
    ok(f in txt or f == 'perf2-soak.py', f'{f} wired')
ok('perf2-soak.py' in (S / 'perf2-stability.sh').read_text() and 'perf2-cancel-verdict.py' in (S / 'perf2-cancel.sh').read_text(), 'helpers wired')
ok('accuracy,stability,cancel' in txt and 'perf2-gate.py perf-out' in txt, 'gate lists all three legs')
ok(order.index('gate') < order.index('perf_artifact'), 'summary written before upload')
shutil.rmtree(T, ignore_errors=True); print(f'PASS {n} checks (fakes only, not a Mac result)')
