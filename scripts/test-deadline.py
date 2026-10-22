#!/usr/bin/env python3
"""Executes scripts/run-with-deadline.py and the real ci.yml step bodies for the compile_only shared deadline and the diag-dir
checkout-clean case. Linux-only, not Mac evidence. Optional: --base-ci FILE runs the missing-diag-dir case against an older ci.yml (old-fail)."""
import os, re, signal, subprocess, sys, tempfile, time, yaml, pathlib
repo = pathlib.Path(__file__).resolve().parent.parent; W = str(repo / 'scripts/run-with-deadline.py')
fails = []
def check(n, ok, d=''):
    print(('ok   ' if ok else 'FAIL ') + n + ('' if ok else ' :: ' + str(d)))
    if not ok: fails.append(n)
def run(args, dl=None, timeout=60, **kw):
    e = dict(os.environ); e.pop('SPZ_COMPILE_DEADLINE_EPOCH', None)
    if dl is not None: e['SPZ_COMPILE_DEADLINE_EPOCH'] = str(int(dl))
    t = time.time(); p = subprocess.run([sys.executable, W] + args, env=e, capture_output=True, text=True, timeout=timeout, **kw)
    return p.returncode, p.stdout + p.stderr, time.time() - t
now = time.time()
rc, o, _ = run(['bash', '-c', 'exit 7']); check('unset deadline: passthrough exit code', rc == 7, rc)
rc, o, _ = run(['bash', '-c', 'echo hi'], dl=now + 60); check('future deadline: runs, exit 0, output kept', rc == 0 and 'hi' in o, (rc, o))
rc, o, _ = run(['bash', '-c', 'exit 3'], dl=now + 60); check('future deadline: command failure code preserved', rc == 3, rc)
m = tempfile.mktemp(); rc, o, dt = run(['bash', '-c', f'touch {m}'], dl=now - 5)
check('expired deadline: command NOT started, exit 124', rc == 124 and not os.path.exists(m) and 'not starting' in o, (rc, o))
m = tempfile.mktemp(); rc, o, dt = run(['bash', '-c', f'(sleep 300; touch {m}) & sleep 300'], dl=now + 3)
check('near deadline: whole process group killed, exit 124, within a few seconds', rc == 124 and dt < 20, (rc, dt)); time.sleep(0.5); check('near deadline: grandchild did not survive to run', not os.path.exists(m))
m = tempfile.mktemp(); rc, o, dt = run(['bash', '-c', f'trap "" TERM; (trap "" TERM; sleep 4; touch {m}) & sleep 300'], dl=now + 2, timeout=60)
check('TERM-ignoring process: SIGKILL escalation, exit 124', rc == 124 and dt < 25, (rc, dt))
# cancel: SIGTERM to wrapper kills group
m = tempfile.mktemp(); e = dict(os.environ, SPZ_COMPILE_DEADLINE_EPOCH=str(int(now + 120)))
p = subprocess.Popen([sys.executable, W, 'bash', '-c', f'(sleep 5; touch {m}) & sleep 300'], env=e); time.sleep(1.5); p.send_signal(signal.SIGTERM)
check('cancel (SIGTERM to wrapper): exits non-zero promptly', p.wait(timeout=20) != 0); time.sleep(6); check('cancel: child group killed', not os.path.exists(m))
# workflow bodies
doc = yaml.safe_load(open(repo / '.github/workflows/ci.yml')); steps = doc['jobs']['macos']['steps']
names = [s.get('name', s.get('uses', '')) for s in steps]
ci = [i for i, s in enumerate(steps) if str(s.get('uses', '')).startswith('actions/checkout')][0]
prep = [i for i, n in enumerate(names) if n.startswith('Prepare diagnostics dir')][0]
eng = [i for i, s in enumerate(steps) if s.get('id') == 'engine'][0]
check('diag/deadline prep step runs AFTER checkout (which cleans the workspace) and BEFORE the engine step', ci < prep < eng)
def body_run(body, env, cwd, base=None):
    e = dict(os.environ); e.pop('SPZ_DIAG_DIR', None); e.update(env)
    return subprocess.run(['bash', '-e', '-c', body], cwd=cwd, env=e, capture_output=True, text=True, timeout=60)
def mkrepo():
    w = tempfile.mkdtemp(); os.makedirs(w + '/scripts'); subprocess.run(['cp', W, w + '/scripts/'])
    open(w + '/scripts/build-engine.sh', 'w').write('#!/bin/bash\necho engine ok\n'); os.chmod(w + '/scripts/build-engine.sh', 0o755); return w
# prep step: deadline and diag dir
w = mkrepo(); gh = w + '/ghenv'; open(gh, 'w').close()
b = steps[prep]['run'].replace('${{ inputs.compile_only }}', 'true')
r = body_run(b, {'GITHUB_WORKSPACE': w, 'GITHUB_ENV': gh, 'SPZ_JOB_DEADLINE_EPOCH': '10000'}, w); envtxt = open(gh).read()
check('prep: creates diag-out in the (cleaned) workspace and exports SPZ_DIAG_DIR', r.returncode == 0 and os.path.isdir(w + '/diag-out') and f'SPZ_DIAG_DIR={w}/diag-out' in envtxt, r.stderr)
check('prep: compile_only deadline = job deadline - 360', 'SPZ_COMPILE_DEADLINE_EPOCH=9640' in envtxt, envtxt)
open(gh, 'w').close(); body_run(steps[prep]['run'].replace('${{ inputs.compile_only }}', 'false'), {'GITHUB_WORKSPACE': w, 'GITHUB_ENV': gh, 'SPZ_JOB_DEADLINE_EPOCH': '10000'}, w)
check('prep: non-compile_only exports NO compile deadline', 'SPZ_COMPILE_DEADLINE_EPOCH' not in open(gh).read())
# reserve arithmetic is tied to the step timeouts
col = [s for s in steps if str(s.get('name', '')).startswith('Collect compile diagnostics')][0]; up = [s for s in steps if str(s.get('name', '')).startswith('Upload compile diagnostics')][0]
check('reserve 360s >= collect + upload step timeouts (300s) + margin', 360 >= (col['timeout-minutes'] + up['timeout-minutes']) * 60 + 60)
# engine step with diag dir MISSING (checkout clean removed it) and the test helper NOT creating it
def engine_body(path):
    d = yaml.safe_load(open(path)); return [s for s in d['jobs']['macos']['steps'] if s.get('id') == 'engine'][0]['run']
w = mkrepo(); miss = w + '/gone/diag-out'
r = body_run(engine_body(repo / '.github/workflows/ci.yml'), {'SPZ_DIAG_DIR': miss}, w)
check('engine step with MISSING diag dir (no helper precreate) succeeds and writes its log', r.returncode == 0 and os.path.exists(miss + '/engine-build.log'), r.stderr)
w = mkrepo(); open(w + '/scripts/build-engine.sh', 'w').write('#!/bin/bash\necho engine bad >&2; exit 5\n')
r = body_run(engine_body(repo / '.github/workflows/ci.yml'), {'SPZ_DIAG_DIR': w + '/gone2'}, w)
check('engine step real failure stays red (exit non-zero) and log retained', r.returncode != 0 and os.path.exists(w + '/gone2/engine-build.log'), r.returncode)
w = mkrepo(); r = body_run(engine_body(repo / '.github/workflows/ci.yml'), {'SPZ_DIAG_DIR': w + '/gone3', 'SPZ_COMPILE_DEADLINE_EPOCH': str(int(time.time()) - 1)}, w)
check('engine step after the shared deadline: not started, step red', r.returncode != 0 and 'engine ok' not in r.stdout, r.stdout)
if '--base-ci' in sys.argv:
    w = mkrepo(); r = body_run(engine_body(sys.argv[sys.argv.index('--base-ci') + 1]), {'SPZ_DIAG_DIR': w + '/gone4/diag-out'}, w)
    print('OLD ci.yml engine step with missing diag dir -> rc', r.returncode, '(old-fail expected non-zero)')
print(f'{len(fails)} failed'); sys.exit(1 if fails else 0)
