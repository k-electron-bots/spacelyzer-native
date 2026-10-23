#!/usr/bin/env python3
"""EXECUTED Linux preflight for scripts/v1-capture.sh with stubbed open/pkill/pgrep/screencapture and a stub accessibility helper.
Proves the control flow only (ordering, independence of shots, refusal to confirm a removal unless the confirmation alert is present,
FDA layout check verdicts). It is NOT a Mac result: real AX menus, sheets, popovers and pixels are unverified until a Mac run."""
import os, subprocess, sys, tempfile, shutil
R = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
fails = []; DUP = []
def ck(n, ok, d=''):
    print(('ok   ' if ok else 'FAIL ') + n + ('' if ok else ' :: ' + str(d))); (ok or fails.append(n))
def run(env_extra):
    t = tempfile.mkdtemp(); os.makedirs(t + '/stubs'); os.makedirs(t + '/scripts')
    for f in ['v1-capture.sh', 'run-bounded.py']: shutil.copy(R + '/scripts/' + f, t + '/scripts/' + f)
    open(t + '/scripts/make-docs-fixture.sh', 'w').write('#!/bin/bash\nmkdir -p "$1"; echo x > "$1/f"\n')
    for c in ['open', 'pkill']: open(t + '/stubs/' + c, 'w').write('#!/bin/bash\nexit 0\n')
    open(t + '/stubs/pgrep', 'w').write('#!/bin/bash\necho 123\n')
    open(t + '/stubs/screencapture', 'w').write('#!/bin/bash\nfor a; do l="$a"; done; echo png > "$l"\n')
    open(t + '/helper', 'w').write('''#!/bin/bash
echo "$*" >> "$LOG"
case "$2" in
 rect) echo "0,0,960,600";;
 hastext) [ "$3" = "Move to Trash?" ] && [ -n "$NOALERT" ] && exit 1; exit 0;;
 choose) [ -n "$NOMENU" ] && exit 1; exit 0;;
 frame) if [ "$3" = "Open System Settings" ]; then echo 800,60,150,22; else echo 20,${FIELDY:-95},300,24; fi;;
 dump) echo tree;;
 press) [ "$3" = "Move selected item to Trash" ] && [ -n "$NOPRESS" ] && exit 1; exit 0;;
esac
''')
    for f in os.listdir(t + '/stubs'): os.chmod(t + '/stubs/' + f, 0o755)
    os.chmod(t + '/helper', 0o755)
    env = dict(os.environ, PATH=t + '/stubs:' + os.environ['PATH'], LOG=t + '/log', HELPER=t + '/helper', SAMPLE=t + '/S', V1_FAST='1', **env_extra)
    open(t + '/log', 'w').close()
    rc = subprocess.run(['bash', 'scripts/v1-capture.sh', '/x/App.app', t + '/out'], cwd=t, env=env, capture_output=True).returncode
    dup = os.path.exists(t + '/S/Documents/Reports/Annual Summary.pdf') and os.path.exists(t + '/S/Downloads/Annual Summary (1).pdf') and open(t + '/S/Documents/Reports/Annual Summary.pdf', 'rb').read() == open(t + '/S/Downloads/Annual Summary (1).pdf', 'rb').read() and os.path.getsize(t + '/S/Downloads/Annual Summary (1).pdf') == 7340032
    DUP.append(dup)
    status = open(t + '/out/v1-capture-status.txt').read(); log = open(t + '/log').read().split('\n')
    shots = sorted(f for f in os.listdir(t + '/out') if f.startswith('screenshot-v1-')); dumps = [f for f in os.listdir(t + '/out') if f.startswith('v1-dump-')]
    shutil.rmtree(t); return rc, status, log, shots, dumps
CONFIRM = '%d press Move to Trash'.replace('%d', '123')
rc, st, log, shots, dumps = run({})
ck('happy path: all 6 shots, done, rc 0', rc == 0 and shots == ['screenshot-v1-duplicates.png', 'screenshot-v1-exclusions.png', 'screenshot-v1-fda-banner.png', 'screenshot-v1-removal-history.png', 'screenshot-v1-trash-confirm.png', 'screenshot-v1-trash-done.png'] and 'FDA-LAYOUT OK' in st, (rc, shots, st))
order = [l for l in log if l]
idx = lambda s: next(i for i, l in enumerate(order) if s in l)
ck('order: exclusions, duplicates, then the trash flow; removal confirmed once, after the alert was checked, before history',
   idx('Exclusions') < idx('Duplicates') < idx('select 0') < idx('Move selected item to Trash') < idx('hastext Move to Trash?') < order.index(CONFIRM) < idx('Removal history')
   and order.count(CONFIRM) == 1, order)
rc, st, log, shots, dumps = run({'NOALERT': '1'})
ck('MUTATION: confirmation alert absent -> the removal is never confirmed, failure recorded, diagnostic dump kept', CONFIRM not in log and 'FAIL trash-confirm' in st and 'v1-dump-trash-confirm.txt' in dumps, (log, st))
rc, st, log, shots, dumps = run({'NOPRESS': '1'})
ck('MUTATION: Trash button not pressable -> nothing confirmed', CONFIRM not in log and 'STEP-FAIL trash-open' in st, (log, st))
rc, st, log, shots, dumps = run({'NOMENU': '1'})
ck('menu failures are independent: cleanup and FDA shots still captured, dumps kept', 'screenshot-v1-trash-confirm.png' in shots and 'screenshot-v1-fda-banner.png' in shots and 'screenshot-v1-exclusions.png' not in shots and len(dumps) == 2, (shots, dumps))
rc, st, log, shots, dumps = run({'FIELDY': '60'})
ck('MUTATION: filter field under the banner -> FDA-LAYOUT FAIL recorded (the pre-fix layout is detected)', 'FDA-LAYOUT FAIL' in st, st)
ck('happy path is the only COMPLETE: rc 0 and COMPLETE line', 'V1-CAPTURE COMPLETE' in run({})[1] and run({})[0] == 0)
for k, v in [('FIELDY', '60'), ('NOMENU', '1'), ('NOALERT', '1')]:
    r = run({k: v}); ck('FAIL-CLOSED: %s=%s -> rc 1 and INCOMPLETE, never COMPLETE' % (k, v), r[0] == 1 and 'V1-CAPTURE INCOMPLETE' in r[1] and 'COMPLETE:' not in r[1].replace('INCOMPLETE:', ''), r[:2])
r = run({'V1_BUDGET': '-1'}); ck('FAIL-CLOSED: exhausted time budget skips shots, rc 1, INCOMPLETE', r[0] == 1 and 'SKIPPED' in r[1] and 'INCOMPLETE' in r[1], r[:2])
ck('capture-owned fixture copy holds an identical non-zero 7 MB duplicate pair in every run', DUP and all(DUP), DUP)
print('\n%d failed' % len(fails)); sys.exit(1 if fails else 0)
