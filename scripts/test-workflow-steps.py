#!/usr/bin/env python3
"""Executes the REAL shell bodies of ci.yml steps (extracted by step id) under bash with stubbed macOS tools, plus the real
final-gate `if:` expression (translated to Python) over a matrix of step outcomes. Linux-only, NOT Mac evidence.
Real: the YAML text of every step run here, scripts/check-ordering-manifest.py against the Sources tree, bash semantics for -e / -eo pipefail.
Stubbed: open, codesign, pkill, pgrep, screencapture, swiftc, sleep, hdiutil, and the app/docs-capture binaries (see STUBS).
Path-substituted: hard-coded /tmp/spz-* and $HOME paths are redirected into a throwaway directory (the only edit made to a step body).
Optional: --base-ci <file> runs the docs cases against an older ci.yml to show the old behavior."""
import os, re, subprocess, sys, tempfile, shutil, yaml, textwrap, stat

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
CI = REPO + '/.github/workflows/ci.yml'
base_ci = None
if '--base-ci' in sys.argv: base_ci = sys.argv[sys.argv.index('--base-ci') + 1]
fails = []; ran = 0

def load(path):
    return yaml.safe_load(open(path))

def step(doc, job, key):
    for s in doc['jobs'][job]['steps']:
        if s.get('id') == key or s.get('name', '').startswith(key): return s
    raise SystemExit('step not found: ' + key)

def check(name, ok, detail=''):
    global ran; ran += 1
    print(('ok   ' if ok else 'FAIL ') + name + (' :: ' + detail if (detail and not ok) else ''))
    if not ok: fails.append(name)

STUBS = {
 'pkill': 'exit 0', 'pgrep': '[ "$STUB_PGREP" = none ] && exit 1; echo 4242', 'open': '''
# open -n APP --stdout F --stderr F --env K=V ... : emulate the ordering driver by writing result files per $STUB_ORDERING
# SPZ_DEMO=1 (the scripted demo launch): emulate the app's ready markers, finished marker and assertion file per $STUB_DEMO (full | nofinish | stall:N | none)
case "${STUB_DEMO:+x} $* " in x*" SPZ_DEMO=1 "*)
  T="$STUB_TMPDIR"
  case "$STUB_DEMO" in
    none) :;;
    *) n=81; case "$STUB_DEMO" in stall:*) n=$((${STUB_DEMO#stall:} - 1));; esac
       for i in $(seq 1 $n); do touch "$T/spz-demo-ready-$i"; done
       [ "$STUB_DEMO" = full ] && { touch "$T/spz-demo-finished"; for i in $(seq 1 176); do echo "PASS c$i d"; done > "$T/spz-assertions.txt"; };;
  esac; exit 0;; esac
rd=""; for a in "$@"; do case "$a" in SPZ_RESULT_DIR=*) rd="${a#SPZ_RESULT_DIR=}";; esac; done
[ -n "$rd" ] || exit 0
case "$STUB_PERF" in
  complete) printf 'PERF-COMPLETE\\n' > "$rd/result.txt"; echo 'cancel 1.2s' > "$rd/perf.txt"; exit 0;;
  incomplete) printf 'PERF-INCOMPLETE missing full-scan milestone\\n' > "$rd/result.txt"; exit 0;;
  none) exit 0;;
esac
case "$STUB_ORDERING" in
  pass) printf 'PASS %s required checks, each exactly once\\n' "$STUB_N" > "$rd/result.txt"; echo "PASS x" > "$rd/assertions.txt";;
  failassert) printf 'PASS %s required checks, each exactly once\\n' "$STUB_N" > "$rd/result.txt"; echo "FAIL x detail" > "$rd/assertions.txt";;
  wronghead) printf 'FAIL 3 of %s\\n' "$STUB_N" > "$rd/result.txt"; echo "FAIL x" > "$rd/assertions.txt";;
  none) :;;
esac; exit 0''',
 'codesign': '[ "$STUB_CODESIGN" = fail ] && exit 1; exit 0', 'sleep': 'exit 0', 'hdiutil': 'exit 0',
 'swiftc': 'out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done; [ -n "$out" ] && cp "$STUB_CAPBIN" "$out" && chmod +x "$out"; exit 0',
 'screencapture': '[ "$STUB_SCREENCAP" = fail ] && exit 1; f=""; for a in "$@"; do f="$a"; done; case "$STUB_SCREENCAP_ONLY" in "") :;; *) case "$f" in *"$STUB_SCREENCAP_ONLY"*) :;; *) exit 1;; esac;; esac; echo png > "$f"; exit 0',
}
CAPBIN = '''#!/bin/bash
# stands in for the compiled docs-capture helper: windowid prints a number, press/select/type/escape succeed
if [ "$2" = windowid ]; then [ "$STUB_WINDOW" = none ] && exit 1; echo 77; fi; exit 0
'''

def workdir():
    w = tempfile.mkdtemp(prefix='spz-steptest-')
    os.makedirs(w + '/bin'); os.makedirs(w + '/dist'); os.makedirs(w + '/home'); os.makedirs(w + '/tmp')
    for n, body in STUBS.items():
        p = w + '/bin/' + n; open(p, 'w').write('#!/bin/bash\n' + body + '\n'); os.chmod(p, 0o755)
    open(w + '/capbin', 'w').write(CAPBIN)
    shutil.copytree(REPO + '/scripts', w + '/scripts'); shutil.copytree(REPO + '/Resources', w + '/Resources'); shutil.copytree(REPO + '/Sources', w + '/Sources')
    # the real fixture builder writes >1 GB of zeros; the step test replaces ONLY that call (see subst)
    return w

def subst(body, w):
    body = body.replace('/tmp/spz-docs-capture', w + '/tmp/spz-docs-capture')
    body = body.replace('/tmp/spz-assertions.txt', w + '/tmp/spz-assertions.txt').replace('/tmp/spz-timing.txt', w + '/tmp/spz-timing.txt')
    body = body.replace('bash scripts/make-docs-fixture.sh "$HOME/Sample"', 'mkdir -p "$HOME/Sample"')
    return body

def run_step(body, w, shellopts, env=None):
    e = dict(os.environ); e.update({'HOME': w + '/home', 'PATH': w + '/bin:' + os.environ['PATH'], 'STUB_CAPBIN': w + '/capbin', 'RUNNER_TEMP': w + '/tmp', 'TMPDIR': w + '/tmp'})
    e.update(env or {})
    p = subprocess.run(['bash'] + shellopts.split() + ['-c', body], cwd=w, env=e, capture_output=True, text=True, timeout=120)
    return p.returncode, p.stdout + p.stderr

DOCS = ['overview','kinds','largest','review','folders','filtered-largest','no-matches','overview-dark','welcome','welcome-dark','fda-banner']

def docs_cases(ci_path, label, expect_gate_fix):
    doc = load(ci_path); body = step(doc, 'macos', 'Docs captures')['run']
    for opts in ('-e', '-eo pipefail'):
        for name, env, want_fail in [
            ('all 11 captures succeed', {}, False),
            ('screencapture fails every time', {'STUB_SCREENCAP': 'fail'}, True),
            ('no window found', {'STUB_WINDOW': 'none'}, True),
            ('only one capture succeeds', {'STUB_SCREENCAP_ONLY': 'overview.png'}, True)]:
            w = workdir(); rc, out = run_step(subst(body, w), w, opts, env)
            got_fail = rc != 0
            if expect_gate_fix: check(f'[{label}] docs step [{opts}] {name}: exit {"!=0" if want_fail else "0"}', got_fail == want_fail, f'rc={rc} {out[-200:]}')
            else: print(f'info [{label}] docs step [{opts}] {name}: rc={rc} (old behavior)')
            if expect_gate_fix and want_fail and name.startswith('only one'):
                check(f'[{label}] error names the 10 missing captures', all(n in out for n in DOCS[1:]) and '::error title=docs-captures' in out, out[-300:])
            shutil.rmtree(w)

def asserts_cases():
    doc = load(CI); body = step(doc, 'macos', 'asserts')['run']
    lines = lambda n, f=0: ''.join((f'FAIL c{i} d\n' if i < f else f'PASS c{i} d\n') for i in range(n))
    def mk(n=176, f=0, shots=81, timing='', extra=None):
        w = workdir(); open(w + '/tmp/spz-assertions.txt', 'w').write(lines(n, f)); open(w + '/tmp/spz-timing.txt', 'w').write(timing)
        for i in range(1, shots + 1): open(f'{w}/dist/screenshot-demo-{i}.png', 'w').write('x')
        return w
    for opts in ('-e', '-eo pipefail'):
        for name, kw, want_fail in [('176 PASS, all screenshots', {}, False), ('175 results', {'n': 175}, True), ('176 results, one FAIL', {'f': 1}, True),
                                    ('80 of 81 screenshots', {'shots': 80}, True), ('APP NOT RUNNING', {'timing': 'APP NOT RUNNING\n'}, True), ('DEMO TIMEOUT', {'timing': 'DEMO x TIMEOUT\n'}, True)]:
            w = mk(**kw); rc, out = run_step(subst(body, w), w, opts); check(f'asserts step [{opts}] {name}: {"fails" if want_fail else "passes"}', (rc != 0) == want_fail, f'rc={rc} {out[-200:]}'); shutil.rmtree(w)
        w = workdir(); rc, out = run_step(subst(body, w), w, opts); check(f'asserts step [{opts}] assertion file absent: fails', rc != 0, out[-200:]); shutil.rmtree(w)
    real = '/downloads/run176/core/ui-assertions.txt'
    if os.path.exists(real):
        w = workdir(); shutil.copy(real, w + '/tmp/spz-assertions.txt')
        for i in range(1, 82): open(f'{w}/dist/screenshot-demo-{i}.png', 'w').write('x')
        open(w + '/tmp/spz-timing.txt', 'w').write('')
        rc, out = run_step(subst(body, w), w, '-e'); check('asserts step on the REAL run-39451419467 ui-assertions.txt (173 PASS, 3 FAIL): fails', rc != 0, out[-200:]); shutil.rmtree(w)
    else: print('info real run evidence not present; skipped')

def ordering_cases():
    doc = load(CI); body = step(doc, 'macos', 'ordering')['run']
    n = re.search(r'OK (\d+) required', subprocess.run(['python3', REPO + '/scripts/check-ordering-manifest.py'], cwd=REPO, capture_output=True, text=True).stdout).group(1)
    for opts in ('-e', '-eo pipefail'):
        for name, env, want_fail in [('driver reports PASS N', {'STUB_ORDERING': 'pass'}, False), ('result.txt never written (timeout path)', {'STUB_ORDERING': 'none'}, True),
                                     ('result header not PASS', {'STUB_ORDERING': 'wronghead'}, True), ('PASS header but a FAIL in assertions', {'STUB_ORDERING': 'failassert'}, True),
                                     ('codesign fails', {'STUB_ORDERING': 'pass', 'STUB_CODESIGN': 'fail'}, True)]:
            w = workdir(); os.makedirs(w + '/dist-test/Spacelyzer.app/Contents/MacOS'); open(w + '/dist-test/Spacelyzer.app/Contents/MacOS/Spacelyzer', 'w').write('x')
            env = dict(env, STUB_N=n); rc, out = run_step(body, w, opts, env)
            check(f'ordering step [{opts}] {name}: {"fails" if want_fail else "passes"}', (rc != 0) == want_fail, f'rc={rc} {out[-250:]}'); shutil.rmtree(w)

def gate_cases():
    doc = load(CI); st = [s for s in doc['jobs']['macos']['steps'] if s.get('name', '').startswith('Fail the build')][0]
    expr = st['if'].strip()[3:-2].strip()
    py = expr.replace('&&', ' and ').replace('||', ' or ').replace('always()', 'True')
    py = re.sub(r'!(?!=)', ' not ', py)
    py = re.sub(r'inputs\.(\w+)', r"I['\1']", py); py = re.sub(r'steps\.(\w+)\.outcome', r"O['\1']", py); py = re.sub(r'steps\.(\w+)\.outputs\.(\w+)', r"U['\1.\2']", py)
    def gate(I=None, O=None, U=None):
        base_I = dict(compile_only=False, perf=False, perf_in_run=False, consolidated=True); base_I.update(I or {})
        base_O = {k: 'success' for k in ['reset', 'docs', 'asserts', 'perf', 'ordering', 'rust', 'bulk', 'dmg']}; base_O.update(O or {})
        base_U = {'testbuild.optional_build': ''}; base_U.update(U or {})
        return bool(eval(py, {}, {'I': base_I, 'O': base_O, 'U': base_U}))
    check('gate does NOT run when everything succeeded (consolidated)', gate() is False)
    for k in ['reset', 'docs', 'asserts', 'ordering', 'rust', 'bulk', 'dmg']:
        for bad in ('failure', 'skipped', 'cancelled'):
            check(f'gate runs when {k} is {bad}', gate(O={k: bad}) is True)
    check('gate runs when testbuild optional_build == failed', gate(U={'testbuild.optional_build': 'failed'}) is True)
    check('gate runs when docs missing because reset failed (docs skipped, reset failure)', gate(O={'reset': 'failure', 'docs': 'skipped'}) is True)
    check('gate does NOT run for compile_only', gate(I={'compile_only': True}, O={'docs': 'failure'}) is False)
    # perf option is exclusive: every other evidence step is skipped by design and must not trip the gate; only perf matters.
    check('perf-exclusive: perf success, other steps skipped -> gate does NOT run', gate(I={'perf': True}, O={'reset': 'skipped', 'docs': 'skipped', 'asserts': 'skipped', 'ordering': 'skipped', 'rust': 'skipped', 'bulk': 'skipped', 'dmg': 'skipped'}) is False)
    for bad in ('failure', 'skipped', 'cancelled'):
        check(f'perf-exclusive: perf {bad} -> gate runs', gate(I={'perf': True}, O={'perf': bad, 'reset': 'skipped', 'docs': 'skipped', 'asserts': 'skipped'}) is True)
    check('perf-exclusive: testbuild optional_build failed -> gate runs', gate(I={'perf': True}, U={'testbuild.optional_build': 'failed'}) is True)
    for bad in ('failure', 'skipped', 'cancelled'):
        check(f'perf_in_run: perf {bad} (everything else success) -> gate runs', gate(I={'perf_in_run': True}, O={'perf': bad}) is True)
    check('perf_in_run: perf success and everything else success -> gate does NOT run', gate(I={'perf_in_run': True}) is False)
    check('perf not requested: a perf outcome of failure/skipped is ignored by the gate', gate(O={'perf': 'skipped'}) is False and gate(O={'perf': 'failure'}) is False)
    # always() keeps the gate after earlier failures, and it sits after every upload step
    names = [s.get('name', '') or s.get('uses', '') for s in doc['jobs']['macos']['steps']]
    gi = [i for i, s in enumerate(doc['jobs']['macos']['steps']) if s.get('name', '').startswith('Fail the build')][0]
    ups = [i for i, s in enumerate(doc['jobs']['macos']['steps']) if str(s.get('uses', '')).startswith('actions/upload-artifact')]
    check('final gate is the last step and follows every artifact upload', gi == len(names) - 1 and all(i < gi for i in ups))

def timing():
    doc = load(CI); job = doc['jobs']['macos']; steps = job['steps']
    tmo = [(s.get('name', '')[:50], s.get('timeout-minutes')) for s in steps if s.get('timeout-minutes')]
    worst = sum(t for _, t in tmo)
    print('info per-step timeouts on the macos job:', tmo, '| sum =', worst, 'min | job timeout-minutes =', job.get('timeout-minutes'))
    observed = {'rust': 90, 'bulk': 152, 'universal': 20, 'swift': 32, 'dmg': 27, 'installer_icon': 17, 'testbuild': 96, 'demo': 509, 'reset': 2, 'ordering': 68}
    docs = open(REPO + '/.github/workflows/ci.yml').read()
    d = step(doc, 'macos', 'Docs captures')['run']
    sl = sum(int(x) for x in re.findall(r'\bsleep (\d+)', d)) + 0
    print(f'info observed run 39451419467 step seconds (real): {sum(observed.values())}s = {sum(observed.values())/60:.1f} min; docs step static sleep seconds in its body: {sl}s (+ app launch/scan time, never measured)')
    check('observed time + docs sleeps leaves headroom under the 35 min job timeout', sum(observed.values()) + sl < 35 * 60 * 0.85, f'{sum(observed.values()) + sl}s')

def perf_cases():
    doc = load(CI); st = step(doc, 'macos', 'perf'); body = st['run'].replace('${{ inputs.perf_root }}', '/Applications')
    assert 'inputs.perf_root' not in body
    for opts in ('-e', '-eo pipefail'):
        for name, env, want_fail in [('driver writes PERF-COMPLETE', {'STUB_PERF': 'complete'}, False), ('driver writes an incomplete result', {'STUB_PERF': 'incomplete'}, True),
                                     ('result.txt never written (timeout path)', {'STUB_PERF': 'none'}, True), ('codesign fails', {'STUB_PERF': 'complete', 'STUB_CODESIGN': 'fail'}, True)]:
            w = workdir(); os.makedirs(w + '/dist-test/Spacelyzer.app/Contents/MacOS'); open(w + '/dist-test/Spacelyzer.app/Contents/MacOS/Spacelyzer', 'w').write('x')
            rc, out = run_step(body, w, opts, env)
            check(f'perf step [{opts}] {name}: {"fails" if want_fail else "passes"}', (rc != 0) == want_fail, f'rc={rc} {out[-250:]}')
            if not want_fail: check(f'perf step [{opts}] copies the result into dist/perf', os.path.exists(w + '/dist/perf/result.txt') and os.path.exists(w + '/dist/perf/perf.txt'))
            shutil.rmtree(w)
    # the step's own if: expression, translated like the gate's
    expr = st['if'].strip()[3:-2].strip()
    py = expr.replace('&&', ' and ').replace('||', ' or ')
    py = re.sub(r'!(?!=)', ' not ', py); py = re.sub(r'inputs\.(\w+)', r"I['\1']", py); py = re.sub(r'steps\.(\w+)\.outputs\.(\w+)', r"U['\1.\2']", py)
    def runs(I=None, U=None):
        b = dict(compile_only=False, perf=False, perf_in_run=False); b.update(I or {}); u = {'testbuild.optional_build': ''}; u.update(U or {})
        return bool(eval(py, {}, {'I': b, 'U': u}))
    check('perf step runs for perf (exclusive)', runs(I={'perf': True}) is True)
    check('perf step runs for perf_in_run', runs(I={'perf_in_run': True}) is True)
    check('perf step does NOT run when neither is set', runs() is False)
    check('perf step does NOT run for compile_only', runs(I={'perf': True, 'compile_only': True}) is False)
    check('perf step does NOT run when the optional test build failed', runs(I={'perf': True}, U={'testbuild.optional_build': 'failed'}) is False)
    # perf-exclusive skips every required evidence step
    skipped = [s.get('id') or s.get('name', '')[:40] for s in doc['jobs']['macos']['steps'] if s.get('id') in ('reset', 'docs', 'asserts', 'ordering', 'rust', 'bulk', 'dmg')]
    for s_ in doc['jobs']['macos']['steps']:
        if s_.get('id') in ('reset', 'docs', 'asserts', 'ordering', 'rust', 'bulk', 'dmg'):
            e2 = re.sub(r'steps\.(\w+)\.outputs\.(\w+)', r"U['\1.\2']", re.sub(r'steps\.(\w+)\.outcome', r"O['\1']", re.sub(r'inputs\.(\w+)', r"I['\1']", s_['if'].strip()[3:-2].strip().replace('&&', ' and ').replace('||', ' or ')))).replace('!', ' not ').replace(' not =', '!=') if 'if' in s_ else 'True'
            I = dict(compile_only=False, perf=True, perf_in_run=False, consolidated=True, docs_2x=False)
            ok = bool(eval(e2.replace('always()', 'True'), {}, {'I': I, 'O': {k: 'success' for k in ('reset', 'docs', 'asserts')}, 'U': {'testbuild.optional_build': ''}})) if 'if' in s_ else True
            check(f'perf-exclusive: step {s_.get("id")} is skipped', ok is False)

def demo_cases():
    doc = load(CI); launch = step(doc, 'macos', 'Launch app and screenshot')['run']; asserts = step(doc, 'macos', 'asserts')['run']
    def prep(opts, env):
        w = workdir(); os.makedirs(w + '/dist-test/Spacelyzer.app/Contents/MacOS'); os.makedirs(w + '/dist/Spacelyzer.app'); os.makedirs(w + '/scripts', exist_ok=True)
        os.makedirs(w + '/home/Library/Logs/DiagnosticReports')
        e = dict(env, STUB_TMPDIR=w + '/tmp')
        body = launch.replace('/tmp/spz-', w + '/tmp/spz-').replace('python3 scripts/capture-interactions.py &', 'true &')
        rc, out = run_step(body, w, opts, e)
        ab = asserts.replace('/tmp/spz-', w + '/tmp/spz-')
        rc2, out2 = run_step(ab, w, opts, e)
        timing = open(w + '/dist/ui-timing.txt').read() if os.path.exists(w + '/dist/ui-timing.txt') else None
        shots = len([f for f in os.listdir(w + '/dist') if f.startswith('screenshot-demo-')])
        return w, rc, out, rc2, out2, timing, shots
    for opts in ('-e', '-eo pipefail'):
        cases = [('app completes all 81 steps and finishes', {'STUB_DEMO': 'full'}, True, True),
                 ('app never signals a step (launch failure)', {'STUB_DEMO': 'none', 'STUB_PGREP': 'none'}, None, False),
                 ('app stalls at step 40', {'STUB_DEMO': 'stall:40'}, None, False),
                 ('all steps signalled but final assertions never finish', {'STUB_DEMO': 'nofinish'}, None, False),
                 ('app crashed before finishing (not running at end)', {'STUB_DEMO': 'stall:12', 'STUB_PGREP': 'none'}, None, False),
                 ('screencapture fails during the demo steps', {'STUB_DEMO': 'full', 'STUB_SCREENCAP': 'fail'}, False, False)]
        for name, env, want_launch_ok, want_asserts_ok in cases:
            w, rc, out, rc2, out2, timing, shots = prep(opts, env)
            if want_launch_ok is not None: check(f'demo launch step [{opts}] {name}: {"completes" if want_launch_ok else "fails"}', (rc == 0) == want_launch_ok, f'rc={rc} {out[-200:]}')
            check(f'demo launch then asserts [{opts}] {name}: asserts step {"passes" if want_asserts_ok else "FAILS"}', (rc2 == 0) == want_asserts_ok, f'launch rc={rc} asserts rc={rc2} timing={timing!r} shots={shots} {out2[-200:]}')
            if name.startswith('app completes'): check(f'demo [{opts}] full run keeps 81 screenshots and a timing file', shots == 81 and timing is not None)
            if name.startswith('app stalls'): check(f'demo [{opts}] stall records the expected step in ui-timing.txt', timing is not None and 'DEMO STEP TIMEOUT: expected 40' in timing, repr(timing))
            if name.startswith('app never'): check(f'demo [{opts}] launch failure records a step timeout and APP NOT RUNNING', timing is not None and 'DEMO STEP TIMEOUT: expected 1' in timing and 'APP NOT RUNNING' in timing, repr(timing))
            if name.startswith('all steps signalled'): check(f'demo [{opts}] missing finish is recorded', timing is not None and 'DEMO FINISH TIMEOUT' in timing, repr(timing))
            shutil.rmtree(w)

asserts_cases(); ordering_cases(); gate_cases(); perf_cases(); demo_cases()
docs_cases(CI, 'head', True)
if base_ci: docs_cases(base_ci, 'base', False)
timing()
print(f'\n{ran} checks, {len(fails)} failed'); sys.exit(1 if fails else 0)
