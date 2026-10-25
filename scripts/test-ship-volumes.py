#!/usr/bin/env python3
"""Linux controls for scripts/ship-volumes.py and engine/tests/real_volume.rs. (1) judge mutations; (2) the REAL engine test against a REAL
tmpfs mount in a private user+mount namespace (separate volume, descend with cross_devices, umount while scanning); (3) an unprivileged
run on plain directories (permission-denied PASS, separate-volume FAIL). Namespaced root cannot be denied by mode 000, so that case must
read NOT-RUN and fail the driver: root never counts as a pass. Not macOS: a real APFS image and hdiutil detach stay native-unverified."""
import importlib.util, json, os, pathlib, subprocess, sys, tempfile
sys.path.insert(0, 'scripts')
spec = importlib.util.spec_from_file_location('shipvol', 'scripts/ship-volumes.py'); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
from ship_common import Checks

GOOD = '''running 1 test
REAL-VOLUME case separate-volume-recorded PASS recorded=1
REAL-VOLUME case permission-denied-recorded PASS recorded=1
REAL-VOLUME case cross-devices-descends PASS found=true
REAL-VOLUME case detach-during-scan-returns PASS scan=Ok
REAL-VOLUME summary PASS
'''
def judged(text, rc=0):
    c = Checks(['volumes-fixture-mounted', 'volumes-cleanup-detached'] + m.REQUIRED[1:-1]); c.ok('volumes-fixture-mounted'); c.ok('volumes-cleanup-detached')
    m.judge(text, c, rc); return c.verdict()
g, p = judged(GOOD); assert g, p
muts = {'not-run': ('REAL-VOLUME not-run (SPZ_RV_ROOT unset)\n', 0), 'empty': ('', 0),
        'denied NOT-RUN': (GOOD.replace('permission-denied-recorded PASS recorded=1', 'permission-denied NOT-RUN running-as-root'), 0),
        'denied FAIL': (GOOD.replace('permission-denied-recorded PASS', 'permission-denied-recorded FAIL'), 101),
        'duplicate case': (GOOD + 'REAL-VOLUME case cross-devices-descends PASS again\n', 0),
        'detach panic': (GOOD.replace('detach-during-scan-returns PASS scan=Ok', 'detach-during-scan-returns FAIL scan panicked'), 101),
        'summary missing': (GOOD.replace('REAL-VOLUME summary PASS\n', ''), 0), 'rc nonzero': (GOOD, 101)}
for name, (t, rc) in muts.items():
    g, p = judged(t, rc); assert not g, (name, p)
print('PASS volume judge accepts a full pass and rejects 8 mutations (not-run, empty, NOT-RUN root, FAIL, duplicate, panic, no summary, bad rc)')

def cargo(env):
    p = subprocess.run(['cargo', 'test', '--manifest-path', 'engine/Cargo.toml', '--test', 'real_volume', '--', '--nocapture', '--test-threads=1'],
                       capture_output=True, text=True, timeout=300, env=dict(os.environ, **env))
    return p.returncode, p.stdout + p.stderr

# (2) real tmpfs mount in a namespace; run the driver there
inner = r'''
import sys, subprocess, json, pathlib, tempfile
sys.path.insert(0, "scripts")
import importlib.util
spec = importlib.util.spec_from_file_location("shipvol", "scripts/ship-volumes.py"); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def attach(vol, work): subprocess.run(["mount", "-t", "tmpfs", "-o", "size=64m", "tmpfs", vol], check=True)
def detach(vol): subprocess.run(["umount", vol])
def mounted(vol): return any((" " + vol + " ") in l for l in open("/proc/mounts"))
out = tempfile.mkdtemp()
c = m.run(out, attach, detach, m.cargo_test, mounted)
good, problems = c.verdict()
print("RESULT", json.dumps({"good": good, "problems": problems, "rows": [(s, n) for s, n, d in c.rows]}))
'''
p = subprocess.run(['unshare', '-rm', '--', sys.executable, '-c', inner], capture_output=True, text=True, timeout=600)
line = [l for l in p.stdout.splitlines() if l.startswith('RESULT ')]
assert line, (p.stdout[-2000:], p.stderr[-2000:])
res = json.loads(line[0][7:]); rows = dict((n, s) for s, n in res['rows'])
assert rows['volumes-fixture-mounted'] == 'PASS' and rows['volumes-separate-volume-recorded'] == 'PASS' and rows['volumes-cross-devices-descends'] == 'PASS' \
    and rows['volumes-detach-during-scan-returns'] == 'PASS' and rows['volumes-cleanup-detached'] == 'PASS', res
assert rows['volumes-permission-denied-recorded'] == 'FAIL' and not res['good'], res   # namespaced root: NOT-RUN is a failure
print('PASS real tmpfs mount: separate volume recorded, cross_devices descends, umount-while-scanning returns, cleanup unmounted; root-run permission case correctly refused as NOT-RUN')

# (3) unprivileged, plain directories
c = m.run(tempfile.mkdtemp(), lambda v, w: None, lambda v: None, cargo, lambda v: True)
rows = dict((n, s) for s, n, d in c.rows)
assert os.geteuid() != 0
assert rows['volumes-permission-denied-recorded'] == 'PASS' and rows['volumes-separate-volume-recorded'] == 'FAIL' and not c.verdict()[0], rows
print('PASS unprivileged plain dirs: permission-denied PASS, separate-volume FAIL (a non-mount fixture cannot pass the volume case)')
