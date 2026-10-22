#!/usr/bin/env python3
"""Controls for accuracy-scale.py itself: shared-deadline INCOMPLETE with partial artifact and no leaked tree, cleanup of a mode-000 dir, cleanup failure is REPORTED
(not hidden), cleanup refuses paths outside its owned boundary, missing skipped-count output fails closed. Needs SPZ_BIN or target/release/spz."""
import importlib.util, json, os, shutil, subprocess, sys, tempfile, glob
H = os.path.dirname(os.path.abspath(__file__)); SPZ = os.environ.get('SPZ_BIN', os.path.join(H, '..', 'target', 'release', 'spz'))
spec = importlib.util.spec_from_file_location('acc', H + '/accuracy-scale.py'); A = importlib.util.module_from_spec(spec); spec.loader.exec_module(A)
fails = []
def ck(n, ok, d=''):
    print(('ok   ' if ok else 'FAIL ') + n + ('' if ok else ' :: ' + str(d))); (ok or fails.append(n))
PRIV = os.path.realpath(tempfile.mkdtemp(prefix='scalectl-'))   # private TMPDIR: leak detection only sees trees this test's children made (no cross-talk with other runs)
os.environ['TMPDIR'] = PRIV; tempfile.tempdir = None
tmp = PRIV
before = set(glob.glob(tmp + '/acc*'))
out = tempfile.mktemp(suffix='.json')
r = subprocess.run([sys.executable, H + '/accuracy-scale.py', '--spz', SPZ, '--sizes', '100000', '--deadline-seconds', '4', '--cleanup-reserve-seconds', '2', '--out', out], capture_output=True, text=True)
d = json.load(open(out)) if os.path.exists(out) else {}
ck('deadline inside one 100k size: exit 3 INCOMPLETE, partial artifact written', r.returncode == 3 and d.get('verdict') == 'INCOMPLETE' and d.get('incomplete'), (r.returncode, d.get('verdict')))
ck('no tree leaked after deadline (incl. mode-000 dir)', set(glob.glob(tmp + '/acc*')) - before - {out} == set() and not d.get('leaks'), (set(glob.glob(tmp + '/acc*')) - before, d.get('leaks')))
ck('total wall time within deadline + small slack (cleanup inside reserve)', d.get('total_seconds', 999) <= 4 + 5, d.get('total_seconds'))
ck('no rows claimed for the interrupted size', d.get('rows') == [] and d.get('failures') == [], (d.get('rows'), d.get('failures')))
# cleanup unit controls
log = []
if os.getuid() != 0:
    x = tempfile.mkdtemp(prefix='acc-ctl-'); os.mkdir(x + '/noperm'); open(x + '/noperm/h', 'w').write('z'); os.chmod(x + '/noperm', 0)
    ck('cleanup removes a tree containing a mode-000 dir via the KNOWN path', A.cleanup(x, {'noperm': x + '/noperm'}, log) and not os.path.exists(x), log)
    y = tempfile.mkdtemp(prefix='acc-ctl-'); os.mkdir(y + '/ro'); open(y + '/ro/f', 'w').write('q'); os.chmod(y + '/ro', 0o500)
    log = []; ok = A.cleanup(y, None, log)
    ck('cleanup failure is REPORTED (False + log), not swallowed', ok is False and log and os.path.exists(y), (ok, log))
    os.chmod(y + '/ro', 0o700); shutil.rmtree(y)
else: print('NOT-RUN: root cannot exercise permission-based cleanup controls')
z = tempfile.mkdtemp(prefix='notowned-'); log = []
ck('cleanup refuses a directory outside the owned name boundary', A.cleanup(z, None, log) is False and os.path.exists(z) and 'REFUSED' in ' '.join(log), log); shutil.rmtree(z)
ck('cleanup refuses a path outside the temp dir', A.cleanup(os.path.expanduser('~'), None, []) is False)
fake = tempfile.mktemp(suffix='.sh'); open(fake, 'w').write('#!/bin/sh\necho "changed format"\n'); os.chmod(fake, 0o755)
q = tempfile.mkdtemp(prefix='acc-ctl-'); dl = A.Deadline(30, 5)
ck('skipped-count output missing => None (caller FAILS, check not disabled)', A.skipped_count(fake, q, dl) is None); os.unlink(fake); shutil.rmtree(q)

import signal, time
def fake(body):
    f = tempfile.mktemp(suffix='.sh'); open(f, 'w').write('#!/bin/sh\n' + body); os.chmod(f, 0o755); return f
def scale(spz, deadline, sizes='1000', timeout=60, ev=None):
    o = tempfile.mktemp(suffix='.json'); t = time.monotonic()
    r = subprocess.run([sys.executable, H + '/accuracy-scale.py', '--spz', spz, '--sizes', sizes, '--deadline-seconds', str(deadline), '--cleanup-reserve-seconds', '2', '--out', o] + (['--evidence-dir', ev] if ev else []), capture_output=True, text=True, timeout=timeout)
    d = json.load(open(o)) if os.path.exists(o) else {}
    if os.path.exists(o): os.unlink(o)
    return r.returncode, d, time.monotonic() - t
def leaked(): return sorted(set(glob.glob(tmp + '/acc*')) - before)
REAL = SPZ
f = fake('sleep 1000'); rc, d, dt = scale(f, 6)
ck('hanging spz: INCOMPLETE rc3 within deadline+slack, nothing claimed, no leak', rc == 3 and d.get('verdict') == 'INCOMPLETE' and d.get('rows') == [] and dt < 6 + 8 and not leaked(), (rc, d.get('verdict'), round(dt, 1), leaked())); os.unlink(f)
f = fake(f'sleep 3; exec "{REAL}" "$@"'); rc, d, dt = scale(f, 5)
ck('slow spz (3s per call) under a 5s budget: INCOMPLETE, never PASS', rc == 3 and d.get('verdict') == 'INCOMPLETE' and d.get('rows') == [] and not leaked(), (rc, d.get('verdict'), round(dt, 1))); os.unlink(f)
f = fake(f'if [ "$1" = verify-cold ] || [ "$1" = dump ]; then echo late > "$2/drift_$$"; fi; exec "{REAL}" "$@"'); rc, d, dt = scale(f, 60)
ck('forced drift (tree changes while the engine runs): INCOMPLETE rc3 with a DRIFT reason, NOT a pass and NOT an engine failure', rc == 3 and d.get('verdict') == 'INCOMPLETE' and d.get('failures') == [] and any('DRIFT' in x[1] for x in d.get('incomplete', [])) and not leaked(), (rc, d.get('verdict'), d.get('incomplete'), d.get('failures'))); os.unlink(f)
f = fake(f'if [ "$1" = dump ]; then "{REAL}" "$@" | python3 -c \'import sys; [sys.stdout.write(l.replace("SKIP\\tPermissionDenied", "SKIP\\tSeparateVolume")) for l in sys.stdin]\'; else exec "{REAL}" "$@"; fi'); rc, d, dt = scale(f, 60)
ck('corrupted skip REASON in the engine output: FAIL rc1 (per-node), not a pass', (os.getuid() == 0) or (rc == 1 and d.get('verdict') == 'FAIL' and any('per-node' in str(x) for x in d.get('failures', []))), (rc, d.get('verdict'), d.get('failures'))); os.unlink(f)
f = fake(f'if [ "$1" = scan ]; then "{REAL}" "$@" | python3 -c \'import re,sys; [sys.stdout.write(re.sub(r" \\(\\d+ skipped\\)", "", l)) for l in sys.stdin]\'; else exec "{REAL}" "$@"; fi'); rc, d, dt = scale(f, 60)
ck('scan output without the skipped field: FAIL rc1 (check not disabled)', rc == 1 and d.get('verdict') == 'FAIL' and any('skipped_count_parsed_and_equal' in x for x in d.get('failures', [])), (rc, d.get('verdict'), d.get('failures'))); os.unlink(f)
flag = tempfile.mktemp(suffix='.once')
f = fake(f'if [ "$1" = dump ] && [ ! -e "{flag}" ] && case "$2" in *acc1000n-*) true;; *) false;; esac; then touch "{flag}"; "{REAL}" "$@" | python3 -c \'import sys; L = sys.stdin.read().split("\\n"); a = L[1].split("\\t"); a[1] = str(int(a[1]) + 512); L[1] = "\\t".join(a); sys.stdout.write("\\n".join(L))\'; else exec "{REAL}" "$@"; fi'); evd = tempfile.mkdtemp(prefix='evd-'); rc, d, dt = scale(f, 60, ev=evd)
ck('one-off per-node diff that does not reproduce: INCOMPLETE rc3 (NON-REPRODUCIBLE), never PASS and never FAIL-as-engine-bug', rc == 3 and d.get('verdict') == 'INCOMPLETE' and any('NON-REPRODUCIBLE' in x[1] for x in d.get('incomplete', [])) and d.get('failures') == [], (rc, d.get('verdict'), d.get('incomplete'), d.get('failures')))
fe = sorted(glob.glob(evd + '/first-diff-*.json')); E = json.load(open(fe[0])) if fe else {}
ck('first failure retained (bounded) before the recheck: complete raw dump and oracle maps, capped diffs/leaf stats with explicit counts, binary hash, platform', len(fe) == 1 and E.get('per_node', {}).get('raw_dump') and E['per_node'].get('all_diffs') and E['per_node'].get('oracle_nodes') and E.get('spz_sha256') and E.get('platform') and 'leaf_stat_after' in E['per_node'] and all(k in E['per_node'] for k in ('diffs_total', 'diffs_kept', 'diffs_dropped', 'diff_cap', 'leaf_stat_cap', 'leaf_stat_kept', 'leaf_stat_dropped_by_cap', 'leaf_stat_missing_path')), (fe, list(E)))
shutil.rmtree(evd, ignore_errors=True)
for x in (f, flag):
    if os.path.exists(x): os.unlink(x)
o = tempfile.mktemp(suffix='.json')
pr = subprocess.Popen([sys.executable, H + '/accuracy-scale.py', '--spz', SPZ, '--sizes', '100000', '--deadline-seconds', '120', '--out', o], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(3); pr.send_signal(signal.SIGTERM); rc = pr.wait(timeout=60); d = json.load(open(o)) if os.path.exists(o) else {}
ck('SIGTERM mid-run: artifact written (interrupted, INCOMPLETE), owned trees incl. mode-000 dir cleaned, nothing claimed', d.get('interrupted') is True and d.get('verdict') == 'INCOMPLETE' and d.get('rows') == [] and not leaked() and not d.get('leaks'), (rc, d.get('interrupted'), d.get('verdict'), leaked()))
if os.path.exists(o): os.unlink(o)
if os.path.exists(out): os.unlink(out)
shutil.rmtree(PRIV, ignore_errors=True)
sys.exit(1 if fails else 0)
