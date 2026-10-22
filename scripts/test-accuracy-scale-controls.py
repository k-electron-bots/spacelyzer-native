#!/usr/bin/env python3
"""Controls for accuracy-scale.py itself: shared-deadline INCOMPLETE with partial artifact and no leaked tree, cleanup of a mode-000 dir, cleanup failure is REPORTED
(not hidden), cleanup refuses paths outside its owned boundary, missing skipped-count output fails closed. Needs SPZ_BIN or target/release/spz."""
import importlib.util, json, os, shutil, subprocess, sys, tempfile, glob
H = os.path.dirname(os.path.abspath(__file__)); SPZ = os.environ.get('SPZ_BIN', os.path.join(H, '..', 'target', 'release', 'spz'))
spec = importlib.util.spec_from_file_location('acc', H + '/accuracy-scale.py'); A = importlib.util.module_from_spec(spec); spec.loader.exec_module(A)
fails = []
def ck(n, ok, d=''):
    print(('ok   ' if ok else 'FAIL ') + n + ('' if ok else ' :: ' + str(d))); (ok or fails.append(n))
tmp = os.path.realpath(tempfile.gettempdir())
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
if os.path.exists(out): os.unlink(out)
sys.exit(1 if fails else 0)
