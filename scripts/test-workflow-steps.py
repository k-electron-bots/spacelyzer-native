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
 'rustup': 'exit 0', 'cargo': '''# stands in for `cargo test`: prints per-binary summaries per $STUB_CARGO (pass | skips | fail | abort)
case "$STUB_CARGO" in
  pass) echo 'test result: ok. 31 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out'; echo 'test result: ok. 20 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out'; exit 0;;
  skips) echo 'test result: ok. 31 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out'; echo 'test result: ok. 20 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out'; printf 'nonutf8_a\\nnonutf8_b\\n' >> "$SPZ_SKIP_MANIFEST"; exit 0;;
  fail) echo 'test result: ok. 31 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out'; echo "thread 'x' panicked at engine/tests/engine.rs:1:1"; echo 'test result: FAILED. 19 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out'; exit 101;;
  abort) echo 'error: could not compile'; exit 101;;
esac''',
 'pkill': 'exit 0', 'pgrep': '[ "$STUB_PGREP" = none ] && exit 1; echo 4242', 'open': '''
# open -n APP --stdout F --stderr F --env K=V ... : emulate the ordering driver by writing result files per $STUB_ORDERING
# SPZ_DEMO=1 (the scripted demo launch): emulate the app's ready markers, finished marker and assertion file per $STUB_DEMO (full | nofinish | stall:N | none)
case "${STUB_DEMO:+x} $* " in x*" SPZ_DEMO=1 "*)
  T="$STUB_TMPDIR"
  case "$STUB_DEMO" in
    none) :;;
    *) n=81; case "$STUB_DEMO" in stall:*) n=$((${STUB_DEMO#stall:} - 1));; esac
       for i in $(seq 1 $n); do touch "$T/spz-demo-ready-$i"; done
       [ "$STUB_DEMO" = full ] && { touch "$T/spz-demo-finished"; for i in $(seq 1 178); do echo "PASS c$i d"; done > "$T/spz-assertions.txt"; };;
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
    def mk(n=178, f=0, shots=81, timing='', extra=None):
        w = workdir(); open(w + '/tmp/spz-assertions.txt', 'w').write(lines(n, f)); open(w + '/tmp/spz-timing.txt', 'w').write(timing)
        for i in range(1, shots + 1): open(f'{w}/dist/screenshot-demo-{i}.png', 'w').write('x')
        return w
    for opts in ('-e', '-eo pipefail'):
        for name, kw, want_fail in [('178 PASS, all screenshots', {}, False), ('177 results', {'n': 177}, True), ('178 results, one FAIL', {'f': 1}, True),
                                    ('80 of 81 screenshots', {'shots': 80}, True), ('APP NOT RUNNING', {'timing': 'APP NOT RUNNING\n'}, True), ('DEMO TIMEOUT', {'timing': 'DEMO x TIMEOUT\n'}, True)]:
            w = mk(**kw); rc, out = run_step(subst(body, w), w, opts); check(f'asserts step [{opts}] {name}: {"fails" if want_fail else "passes"}', (rc != 0) == want_fail, f'rc={rc} {out[-200:]}'); shutil.rmtree(w)
        w = workdir(); rc, out = run_step(subst(body, w), w, opts); check(f'asserts step [{opts}] assertion file absent: fails', rc != 0, out[-200:]); shutil.rmtree(w)
    for real, label, want_fail in [('/downloads/run176/0.1.176/ui-assertions.txt', 'run-39451419467 (176 lines, 3 FAIL)', True),
                                   ('/downloads/run177/0.1.177/ui-assertions.txt', 'run-39602481035 (178 PASS, 0 FAIL)', False)]:
        if os.path.exists(real):
            w = workdir(); shutil.copy(real, w + '/tmp/spz-assertions.txt')
            for i in range(1, 82): open(f'{w}/dist/screenshot-demo-{i}.png', 'w').write('x')
            open(w + '/tmp/spz-timing.txt', 'w').write('')
            rc, out = run_step(subst(body, w), w, '-e'); check(f'asserts step on the REAL {label} ui-assertions.txt: {"fails" if want_fail else "passes"}', (rc != 0) == want_fail, out[-200:]); shutil.rmtree(w)
        else: print(f'info real run evidence not present ({real}); skipped')

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
    # The gate names the failing evidence (run 39602481035's bare `exit 1` hid which outcome tripped it).
    # Execute the REAL gate body with the ${{ }} expressions substituted per scenario; the annotation must name
    # exactly the triggering steps - no more (perf-exclusive skips are by design), no less.
    def render_gate(I, O, U):
        body = st['run']
        def sub(m):
            e = m.group(0)
            mi = re.fullmatch(r'\$\{\{ inputs\.(\w+) \}\}', e)
            if mi: return {'compile_only': 'false', 'perf': 'false', 'perf_in_run': 'false', 'consolidated': 'true', **I}[mi.group(1)]
            mo = re.fullmatch(r'\$\{\{ steps\.(\w+)\.outcome \}\}', e)
            if mo: return {'reset': 'success', 'docs': 'success', 'asserts': 'success', 'perf': 'success', 'ordering': 'success', 'rust': 'success', 'bulk': 'success', 'dmg': 'success', **O}[mo.group(1)]
            mu = re.fullmatch(r'\$\{\{ steps\.testbuild\.outputs\.(\w+) \}\}', e)
            if mu: return U.get('testbuild.' + mu.group(1), '')
            raise AssertionError(e)
        return re.sub(r'\$\{\{[^}]+\}\}', sub, body)
    def gate_msg(I, O, U=None):
        w = workdir(); rc, out = run_step(render_gate(I, O, U or {}), w, '-eo pipefail'); shutil.rmtree(w)
        assert rc == 1, f'gate body rc={rc} out={out[-200:]}'
        m = re.search(r'::error title=evidence-gate::failed or lost evidence:(.*)', out)
        assert m, out[-300:]
        return m.group(1).strip()
    msg = gate_msg({'consolidated': 'true'}, {'bulk': 'failure'})
    check('gate annotation names only bulk when only bulk failed', msg == 'bulk=failure', msg)
    msg = gate_msg({'perf': 'true'}, {'perf': 'failure', 'reset': 'skipped', 'docs': 'skipped', 'asserts': 'skipped', 'ordering': 'skipped', 'rust': 'skipped', 'bulk': 'skipped', 'dmg': 'skipped'})
    check('perf-exclusive: annotation names only perf, not the by-design skips', msg == 'perf=failure', msg)
    msg = gate_msg({}, {'reset': 'failure', 'docs': 'skipped'})
    check('reset failure + docs skipped: both named in order', msg == 'reset=failure docs=skipped', msg)
    msg = gate_msg({'perf_in_run': 'true'}, {'perf': 'failure'})
    check('perf_in_run: annotation names perf', 'perf=failure' in msg, msg)
    msg = gate_msg({}, {}, {'testbuild.optional_build': 'failed'})
    check('testbuild optional build failure is named', msg == 'testbuild(optional_build)=failed', msg)
    msg = gate_msg({'consolidated': 'false'}, {'asserts': 'failure', 'ordering': 'skipped', 'rust': 'skipped', 'bulk': 'skipped', 'dmg': 'skipped'})
    check('non-consolidated: names asserts only, skipped consolidated steps not listed', msg == 'asserts=failure', msg)
    check('gate body is no longer a bare exit 1', st['run'].strip() != 'exit 1')

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

def rust_cases():
    doc = load(CI); body = step(doc, 'macos', 'rust')['run']
    for opts in ('-e', '-eo pipefail'):
        for name, env, want_rc0, want_in in [('all pass', {'STUB_CARGO': 'pass'}, True, ['raw passed=51 failed=0', 'exercised passes=51', 'cargo exit=0']),
                                             ('passes with 2 platform skips', {'STUB_CARGO': 'skips'}, True, ['raw passed=51', 'NOT EXERCISED (platform skips, counted as passed by cargo)=2', 'exercised passes=49', 'nonutf8_a']),
                                             ('one test fails', {'STUB_CARGO': 'fail'}, False, ['cargo exit=101', 'APPROXIMATE', '::error::']),
                                             ('cargo cannot compile', {'STUB_CARGO': 'abort'}, False, ['cargo exit=101', 'raw passed=0'])]:
            w = workdir(); b = body.replace('/tmp/cargotest.log', w + '/tmp/cargotest.log')
            rc, out = run_step(b, w, opts, dict(env))
            check(f'rust step [{opts}] {name}: {"exit 0" if want_rc0 else "fails"}', (rc == 0) == want_rc0, f'rc={rc} {out[-300:]}')
            check(f'rust step [{opts}] {name}: accounting lines {want_in[:2]}', all(x in out for x in want_in), out[-500:])
            shutil.rmtree(w)

def testbuild_cases():
    doc = load(CI); body = step(doc, 'macos', 'testbuild')['run']
    def run(opts, inputs, env):
        w = workdir(); open(w + '/scripts/build-test-app.sh', 'w').write('#!/bin/bash\n[ -n "$SPZ_TEST_EXTRA_DEFINES" ] && [ "$STUB_BUILD_OPT" = fail ] && exit 1\n[ -z "$SPZ_TEST_EXTRA_DEFINES" ] && [ "$STUB_BUILD_CORE" = fail ] && exit 1\nexit 0\n')
        b = body.replace('${{ steps.sign.outputs.hash }}', 'HASH')
        for k, v in {**dict(perf='false', perf_in_run='false', docs_2x='false'), **inputs}.items(): b = b.replace('${{ inputs.%s }}' % k, v)
        out_file = w + '/gh_output'; open(out_file, 'w').write('')
        rc, out = run_step(b, w, opts, dict(env, GITHUB_OUTPUT=out_file))
        o = open(out_file).read(); shutil.rmtree(w); return rc, out, o
    for opts in ('-e', '-eo pipefail'):
        rc, out, o = run(opts, {}, {}); check(f'testbuild [{opts}] default build ok: exit 0, no optional_build output', rc == 0 and 'optional_build' not in o, f'{rc} {o}')
        rc, out, o = run(opts, {}, {'STUB_BUILD_CORE': 'fail'}); check(f'testbuild [{opts}] core build fails: step fails', rc != 0, f'{rc} {out[-200:]}')
        rc, out, o = run(opts, {'perf_in_run': 'true'}, {}); check(f'testbuild [{opts}] perf_in_run, optional ok: optional_build=ok, exit 0', rc == 0 and 'optional_build=ok' in o, f'{rc} {o}')
        rc, out, o = run(opts, {'perf_in_run': 'true'}, {'STUB_BUILD_OPT': 'fail'}); check(f'testbuild [{opts}] perf_in_run, optional fails to compile: core rebuilt, exit 0, optional_build=failed', rc == 0 and 'optional_build=failed' in o and 'Rebuilding the core' in out, f'{rc} {o} {out[-200:]}')
        rc, out, o = run(opts, {'perf_in_run': 'true'}, {'STUB_BUILD_OPT': 'fail', 'STUB_BUILD_CORE': 'fail'}); check(f'testbuild [{opts}] optional AND core fail: step fails', rc != 0, f'{rc}')
        rc, out, o = run(opts, {'perf': 'true'}, {'STUB_BUILD_OPT': 'fail'}); check(f'testbuild [{opts}] perf-exclusive, optional fails: exit 1 with optional_build=failed', rc != 0 and 'optional_build=failed' in o, f'{rc} {o}')
        rc, out, o = run(opts, {'docs_2x': 'true'}, {'STUB_BUILD_OPT': 'fail'}); check(f'testbuild [{opts}] docs_2x optional fails: core rebuilt, optional_build=failed', rc == 0 and 'optional_build=failed' in o, f'{rc} {o}')

def bulk_cases():
    """The real bulk step body. Contract under test: fixture, /Applications and /usr/lib are BINDING (mismatch, error, or absent root all fail the step, every
    probe still runs); $HOME/Library is INFORMATIONAL (reported as a warning with the log, never a gate). spz is a stub that exits per STUB_BULK."""
    doc = load(CI); body = step(doc, 'macos', 'bulk')['run']
    def run(opts, codes=None, absent=()):
        w = workdir(); os.makedirs(w + '/target/release'); os.makedirs(w + '/home/Library', exist_ok=True)
        for d in ('Applications', 'usrlib'):
            if d not in absent: os.makedirs(w + '/' + d)
        if 'Library' in absent: shutil.rmtree(w + '/home/Library')
        open(w + '/bin/cargo', 'w').write('#!/bin/bash\nexit 0\n'); os.chmod(w + '/bin/cargo', 0o755)
        spz = ('#!/bin/bash\nb=$(basename "$2"); code=$(echo ",$STUB_BULK," | tr "," "\\n" | sed -n "s/^$b=//p" | head -1)\n'
               'if [ "$b" = bulk-fixture ]; then echo "files=$(find "$2" -type f | wc -l | tr -d " ") links=$(find "$2" -type l | wc -l | tr -d " ")"; fi\n'
               'case "${code:-0}" in 0) echo "OK backends agree $b";; 1) echo "MISMATCH $b";; *) echo "scan failed $b"; exit "$code";; esac; [ "${code:-0}" = 1 ] && exit 1; exit 0\n')
        open(w + '/target/release/spz', 'w').write(spz); os.chmod(w + '/target/release/spz', 0o755)
        b = body.replace('/Applications', w + '/Applications').replace('/usr/lib', w + '/usrlib')
        rc, out = run_step(b, w, opts, {'STUB_BULK': ','.join(f'{k}={v}' for k, v in (codes or {}).items())})
        summ = open(w + '/tmp/bulk-verify/summary.txt').read() if os.path.exists(w + '/tmp/bulk-verify/summary.txt') else ''
        shutil.rmtree(w); return rc, out, summ
    for opts in ('-e', '-eo pipefail'):
        rc, out, sm = run(opts); check(f'bulk [{opts}] clean pass: exit 0, four AGREE lines, fixture has 308 files + 1 symlink', rc == 0 and sm.count('AGREE') == 4 and 'files=308 links=1' in out, f'{rc} {sm} {out[-300:]}')
        for name, key in [('fixture', 'bulk-fixture'), ('/Applications', 'Applications'), ('/usr/lib', 'usrlib')]:
            rc, out, sm = run(opts, {key: 1}); check(f'bulk [{opts}] {name} MISMATCH alone: step FAILS, all 4 probes still ran', rc != 0 and f'MISMATCH binding' in sm and len(sm.strip().splitlines()) == 4 and '::error title=bulk-verify::MISMATCH' in out, f'{rc} {sm}')
        rc, out, sm = run(opts, {'Library': 1}); check(f'bulk [{opts}] ~/Library MISMATCH alone: exit 0 but warning + summary line + log kept', rc == 0 and 'MISMATCH informational' in sm and '::warning title=bulk-verify::MISMATCH' in out and 'MISMATCH Library' in out, f'{rc} {sm}')
        rc, out, sm = run(opts, {'Applications': 101}); check(f'bulk [{opts}] scan error (exit 101) on /Applications: FAILS as ERROR, not as parity', rc != 0 and 'ERROR(exit 101) binding' in sm, f'{rc} {sm}')
        rc, out, sm = run(opts, {'Library': 101}); check(f'bulk [{opts}] scan error on ~/Library: exit 0, surfaced as informational ERROR', rc == 0 and 'ERROR(exit 101) informational' in sm and '::warning' in out, f'{rc} {sm}')
        rc, out, sm = run(opts, {'bulk-fixture': 1, 'usrlib': 1}); check(f'bulk [{opts}] two binding failures: FAILS, both reported, count says 2', rc != 0 and out.count('::error title=bulk-verify::MISMATCH') == 2 and '2 binding probe(s) failed' in out, f'{rc} {out[-300:]}')
        rc, out, sm = run(opts, {'bulk-fixture': 1, 'Applications': 1, 'usrlib': 101, 'Library': 1}); check(f'bulk [{opts}] all four fail: FAILS, 3 binding errors + 1 warning, every log printed', rc != 0 and '3 binding probe(s) failed' in out and out.count('MISMATCH bulk-fixture') + out.count('MISMATCH Applications') == 2 and 'scan failed usrlib' in out and 'MISMATCH Library' in out, f'{rc} {sm}')
        rc, out, sm = run(opts, absent=('Applications',)); check(f'bulk [{opts}] /Applications absent: FAILS as binding root absent (not parity)', rc != 0 and 'ABSENT binding applications' in sm and 'binding root absent' in out, f'{rc} {sm}')
        rc, out, sm = run(opts, absent=('Library',)); check(f'bulk [{opts}] ~/Library absent: exit 0, warned as not compared', rc == 0 and 'ABSENT informational' in sm and 'not compared' in out, f'{rc} {sm}')


def bulk_bsd_head_case():
    """Run 39602481035: the fixture loop `head -c "$n"` with n=0 fails on macOS BSD head ('illegal byte count -- 0');
    GNU head accepts 0, so a Linux-only pass proves nothing. Execute the REAL bulk step's fixture line under a head shim
    with BSD semantics: the pre-fix line must fail, the current line must pass and produce all six fixture files."""
    doc = load(CI); body = step(doc, 'macos', 'bulk')['run']
    line = next((l.strip() for l in body.splitlines() if l.strip().startswith('for n in 0 1 4095')), None)
    check('bulk fixture loop found in the real step', line is not None)
    shim = ('#!/bin/sh\n'
            'case " $* " in *" -c 0 "*|*" -c0 "*) echo "head: illegal byte count -- 0" >&2; exit 1;; esac\n'
            'exec /usr/bin/head "$@"\n')
    prefix = 'for n in 0 1 4095 4096 4097 1048576; do head -c "$n" /dev/zero > "$F/a/f$n.bin"; done'
    for name, snippet, want_fail in [('pre-fix loop (BSD head shim): FAILS', prefix, True),
                                     ('current step loop (BSD head shim): passes', line, False)]:
        w = workdir(); os.makedirs(w + '/shim'); open(w + '/shim/head', 'w').write(shim); os.chmod(w + '/shim/head', 0o755)
        os.makedirs(w + '/fx/a')
        rc, out = run_step('F="' + w + '/fx"\n' + snippet, w, '-e', {'PATH': w + '/shim:' + os.environ['PATH']})
        check(f'bulk {name}', (rc != 0) == want_fail, f'rc={rc} {out[-200:]}')
        if not want_fail:
            sizes = {n: os.path.getsize(f'{w}/fx/a/f{n}.bin') for n in (0, 1, 4095, 4096, 4097, 1048576)} if rc == 0 else {}
            check('bulk BSD-shim fixture has the six exact sizes', sizes == {0: 0, 1: 1, 4095: 4095, 4096: 4096, 4097: 4097, 1048576: 1048576}, repr(sizes))
        shutil.rmtree(w)

def docs_review_flow_case():
    """Run 39602481035: the docs review capture pressed the visible title "Check on disk", which matches nothing - the
    SelectionBar opener's accessibility label is "Check selected item on disk, read only" (TreemapView.swift), and the
    review is a popover (separate window), so a window-id capture would miss it. Static pins for the repaired flow;
    Mac verification of the capture itself remains open."""
    ci = open(CI).read()
    check('docs review presses the opener by its real accessibility label', 'press "Check selected item on disk, read only"' in ci)
    check('docs review no longer presses the unmatched visible title', 'press "Check on disk"' not in ci)
    check('docs review capture is full-screen (popover is a separate window)', 'screencapture -x "dist/screenshot-docs-review.png"' in ci)
    src = open(REPO + '/scripts/docs-capture.swift').read()
    check('docs-capture matches AXLabel as well as AXTitle/AXDescription/AXValue', 'AXLabel' in src)
    app = open(REPO + '/Sources/Spacelyzer/TreemapView.swift').read()
    check('the pressed label still exists in the source (SelectionBar)', 'Check selected item on disk, read only' in app)

def sheet_line_case():
    """Run 39602481035: batch7-not-scanned-sheet-opened PASSED but printed the failure-branch message ("did not attach").
    Pin the factual message naming both observed facts on pass and fail."""
    app = open(REPO + '/Sources/Spacelyzer/SpacelyzerApp.swift').read()
    check('batch7 sheet line states openerPressed and sheetAttached', 'openerPressed=' in app and 'sheetAttached=' in app)
    check('batch7 sheet line no longer prints the failure-branch text unconditionally', 'pressedSkip7 ? "footer opener pressed via AX' not in app)

def dmg_label_plate_case():
    """Run 39602481035's screenshot-dmg-window.png: Finder draws the icon labels black, and on the navy background
    'Spacelyzer' / 'Applications' were barely readable (polish defect). The background now carries a light plate
    behind each label zone (positions calibrated from the real capture: labels at y ~275-305 under the pinned icon
    positions). Stdlib PNG decode; asserts both plates are light and the window body between them stays navy."""
    import zlib, struct
    def pixels(path):
        d = open(path, 'rb').read()
        assert d[:8] == b'\x89PNG\r\n\x1a\n', path
        pos = 8; w = h = None; depth = ctype = None; idat = b''
        while pos < len(d):
            ln = struct.unpack('>I', d[pos:pos+4])[0]; typ = d[pos+4:pos+8]; chunk = d[pos+8:pos+8+ln]; pos += 12 + ln
            if typ == b'IHDR': w, h, depth, ctype = struct.unpack('>IIBB', chunk[:10])
            elif typ == b'IDAT': idat += chunk
            elif typ == b'IEND': break
        assert depth == 8 and ctype in (2, 6), f'{path}: unsupported depth={depth} ctype={ctype}'
        ch = 3 if ctype == 2 else 4; raw = zlib.decompress(idat); stride = w * ch; out = bytearray(); prev = bytearray(stride)
        i = 0
        for _ in range(h):
            f = raw[i]; line = bytearray(raw[i+1:i+1+stride]); i += 1 + stride
            for x in range(stride):
                a = line[x-ch] if x >= ch else 0; b = prev[x]; c = prev[x-ch] if x >= ch else 0
                if f == 1: line[x] = (line[x] + a) & 255
                elif f == 2: line[x] = (line[x] + b) & 255
                elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
                elif f == 4:
                    p_ = a + b - c; pa, pb, pc = abs(p_-a), abs(p_-b), abs(p_-c)
                    line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
            out += line; prev = line
        return w, h, ch, out
    def lum(w, ch, buf, x0, x1, y0, y1):
        tot = n = 0
        for y in range(y0, y1):
            for x in range(x0, x1):
                o = (y*w + x)*ch; r, g, b = buf[o], buf[o+1], buf[o+2]
                tot += (0.2126*r + 0.7152*g + 0.0722*b) / 255; n += 1
        return tot / n
    for path, sc in [('Resources/dmg-background.png', 1), ('Resources/dmg-background@2x.png', 2)]:
        w, h, ch, buf = pixels(REPO + '/' + path)
        for cx in (190, 470):
            m = lum(w, ch, buf, (cx-85)*sc, (cx+85)*sc, 270*sc, 310*sc)
            check(f'{path}: label plate under icon x={cx} is light (lum {m:.2f} >= 0.75)', m >= 0.75, f'{m:.3f}')
        mid = lum(w, ch, buf, 320*sc, 340*sc, 270*sc, 310*sc)
        check(f'{path}: body between the plates stays navy (lum {mid:.2f} < 0.45)', mid < 0.45, f'{mid:.3f}')

asserts_cases(); ordering_cases(); gate_cases(); perf_cases(); demo_cases(); rust_cases(); testbuild_cases(); bulk_cases(); dmg_label_plate_case(); bulk_bsd_head_case(); docs_review_flow_case(); sheet_line_case()
docs_cases(CI, 'head', True)
if base_ci: docs_cases(base_ci, 'base', False)
timing()
print(f'\n{ran} checks, {len(fails)} failed'); sys.exit(1 if fails else 0)
