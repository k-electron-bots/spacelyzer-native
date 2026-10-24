#!/usr/bin/env python3
"""Static + EXECUTED checks for .github/workflows/demo-only.yml (Linux; the workflow itself is NOT run here, so nothing below is a Mac result).
The copied steps are re-derived from ci.yml and compared byte for byte; the evidence gate and the UI-assertion step are run as real bash against forced failure/skip/cancel/missing-state/missing-artifact cases."""
import os, re, shutil, subprocess, sys, tempfile
try: import yaml
except ImportError: print('FAIL pyyaml missing'); sys.exit(1)
R = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')); W = R + '/.github/workflows/demo-only.yml'
fails = []
def ck(n, ok, d=''):
    print(('ok   ' if ok else 'FAIL ') + n + ('' if ok else ' :: ' + str(d))); (ok or fails.append(n))
def mine_all(t):
    i = t.index('id: testbuild'); return t[i:t.index('- name: Reset persisted')]
txt = open(W).read(); d = yaml.safe_load(txt); on = d.get('on', d.get(True)); ci = open(R + '/.github/workflows/ci.yml').read(); L = ci.split('\n')
ck('dispatch-only, no inputs, no schedule/push/PR/tag', on == {'workflow_dispatch': None}, on)
ck('permissions contents:read only', d['permissions'] == {'contents': 'read'})
ck('jobs are exactly identity-guard and macos; macos needs identity-guard', set(d['jobs']) == {'identity-guard', 'macos'} and d['jobs']['macos']['needs'] == 'identity-guard')
def block(t): i = t.index('  identity-guard:'); return t[i:t.index('  macos:')]
ck('identity-guard byte-identical to accuracy-only and scale-only', block(txt) == block(open(R + '/.github/workflows/accuracy-only.yml').read()) == block(open(R + '/.github/workflows/scale-only.yml').read()))
m = d['jobs']['macos']; ck('macos runner, 35 min job cap', m['runs-on'] == 'macos-latest' and m['timeout-minutes'] == 35)
ck('no secrets, signing, DMG, release, 1M scale, docs captures, Rust test, bulk or write permission',
   not re.search(r'secrets\.|sign-setup|package-dmg|\.dmg|run-scale-check|gh release|softprops|contents:\s*write|cargo test|docs-capture-2x|bulk-vs', re.sub(r'(?m)^#.*$', '', txt)))
ck('optional perf/2x code can never be selected (every guard compares the literal "false")', len(re.findall(r'\[ "(\w+)" = "true" \]', tb_txt := mine_all(txt))) == 3 and set(re.findall(r'\[ "(\w+)" = "true" \]', tb_txt)) == {'false'})
ck('no input references left', 'inputs.' not in txt and 'steps.sign' not in txt and 'steps.ver' not in txt)
uses = sorted({s['uses'] for s in m['steps'] if 'uses' in s}); ck('only checkout@v4 and upload-artifact@v4', uses == ['actions/checkout@v4', 'actions/upload-artifact@v4'], uses)
ck('checkout does not persist credentials', any(s.get('uses') == 'actions/checkout@v4' and s.get('with', {}).get('persist-credentials') is False for s in m['steps']))
# --- copied steps re-derived from ci.yml
mi = next(i for i, l in enumerate(L) if l.startswith('  macos:')); starts = [i for i in range(mi, len(L)) if L[i].startswith('      - ')]
def cstep(prefix):
    for k, s in enumerate(starts):
        if L[s].startswith('      - name: ' + prefix): return '\n'.join(L[s:starts[k + 1]]).rstrip('\n') + '\n'
    raise SystemExit('ci.yml step missing: ' + prefix)
def dropif(t): return re.sub(r'(?m)^        if: .*\n', '', t)
def mine(prefix):
    wl = txt.split('\n'); mi2 = next(i for i, l in enumerate(wl) if l.startswith('  macos:')); st = [i for i in range(mi2, len(wl)) if wl[i].startswith('      - ')]
    for k, s in enumerate(st):
        if wl[s].startswith('      - name: ' + prefix): return '\n'.join(wl[s:(st[k + 1] if k + 1 < len(st) else len(wl))]).rstrip('\n') + '\n'
    raise SystemExit('demo-only step missing: ' + prefix)
for p in ['Anchor hard35min', 'Toolchain versions', 'Build universal engine', 'Build Swift app', 'Typecheck the on-demand helper tools']:
    ck(f'verbatim from ci.yml: {p}', dropif(mine(p)) == dropif(cstep(p)))
ck('verbatim (version output only): Version', dropif(mine('Version')) == dropif(cstep('Version')))
tb = dropif(cstep('Build TEST-ONLY app')); 
for a, b in [('${{ inputs.perf }}', 'false'), ('${{ inputs.perf_in_run }}', 'false'), ('${{ inputs.docs_2x }}', 'false'), ('"${{ steps.sign.outputs.hash }}"', '""')]: tb = tb.replace(a, b)
ck('test-only build = ci.yml with only perf/2x/sign inputs resolved to the technical values', dropif(mine('Build TEST-ONLY app')) == tb)
ck('reset step verbatim', dropif(mine('Reset persisted app state')) == dropif(cstep('Reset persisted app state')))
ul = dropif(cstep('Launch app and screenshot')).replace('"${{ inputs.technical_hardening }}"', '"true"').replace('        continue-on-error: true\n', '        continue-on-error: true\n        timeout-minutes: 12\n')
ck('demo launch step = ci.yml with technical_hardening resolved true (no welcome shots) and a 12 min timeout', dropif(mine('Launch app and screenshot')) == ul)
ck('UI assertions verbatim (178 expected, 81 shots, check-demo-state)', dropif(mine('UI assertions')) == dropif(cstep('UI assertions')) and 'expected=178' in mine('UI assertions') and 'check-demo-state.py /tmp 81' in mine('UI assertions'))
ids = {s.get('id'): s for s in m['steps']}
ck('reset and test build stop the job on failure (success()); launch needs both; assertions run after any launch outcome but not when skipped',
   ids['testbuild'].get('if') == '${{ success() }}' and ids['reset'].get('if') == '${{ success() }}' and 'steps.reset.outcome' in ids['ui_launch']['if'] and 'steps.testbuild.outcome' in ids['ui_launch']['if'] and ids['asserts']['if'] == "${{ always() && steps.ui_launch.outcome != 'skipped' }}")
ck('job clock anchored 2100s; builds must end 1380s before it; reset 2 + demo 12 min caps', '+ 2100' in mine('Anchor') and 'SPZ_JOB_DEADLINE_EPOCH - 1380' in mine('Prepare artifact') and ids['reset']['timeout-minutes'] == 2 and ids['ui_launch']['timeout-minutes'] == 12)
ck('artifact upload always, fails if nothing found, carries shots, state records, assertions, timing, reset evidence',
   ids['demo_artifact']['if'] == '${{ always() }}' and ids['demo_artifact']['with']['if-no-files-found'] == 'error' and all(x in ids['demo_artifact']['with']['path'] for x in ['screenshot-demo-*.png', 'dist/demo-state/', 'ui-assertions.txt', 'ui-timing.txt', 'docs-reset-evidence.txt']))
v1 = ids['v1cap']; vorder = [s.get('id') for s in m['steps']]
ck('v1 capture step: informational, 3 min cap, after the demo and before assertions, needs reset and test build, never runs on a failed build',
   v1['timeout-minutes'] == 3 and v1.get('continue-on-error') is True and vorder.index('ui_launch') < vorder.index('v1cap') < vorder.index('asserts')
   and 'steps.reset.outcome' in v1['if'] and 'steps.testbuild.outcome' in v1['if'] and 'v1cap' in gate_ids if (gate_ids := re.findall(r"add (\w+) ", [s for s in m['steps'] if s.get('name', '').startswith('Demo-validation evidence gate')][0]['run'])) is not None else False)
ck('v1 captures are uploaded; capture script uses the test-only app and no DMG, signing or release', 'dist/v1-capture/' in ids['demo_artifact']['with']['path'] and 'dist-test/Spacelyzer.app' in v1['run']
   and not re.search(r'dmg|sign|release|secrets', open(R + '/scripts/v1-capture.sh').read(), re.I))
hb = next(x for x in m['steps'] if x.get('name', '').startswith('Build the capture helper'))
ck('capture helper is built inside the compile budget (run-with-deadline, before reset and the demo), not inside the v1 capture budget',
   'run-with-deadline.py swiftc scripts/docs-capture.swift -o /tmp/spz-docs-capture' in hb['run'] and m['steps'].index(hb) < vorder.index('reset') and 'job-1380s' in txt and 'FAIL-CLOSED' in v1['name'])
# --- executed: evidence gate
gate_step = [s for s in m['steps'] if s.get('name', '').startswith('Demo-validation evidence gate')][0]; ck('gate runs always', gate_step['if'] == '${{ always() }}')
GK = ['engine', 'swiftapp', 'testbuild', 'reset', 'ui_launch', 'asserts', 'v1cap', 'demo_artifact', 'ordering', 'ordering_artifact']
def run_gate(outc):
    body = gate_step['run']
    for k in GK: body = body.replace('${{ steps.%s.outcome }}' % k, outc.get(k, 'success'))
    assert '${{' not in body, body
    return subprocess.run(['bash', '-e', '-c', body], capture_output=True, text=True)
r = run_gate({}); ck('gate: all steps success -> rc0', r.returncode == 0, r.stdout + r.stderr)
for k in GK:
    for bad in ('failure', 'skipped', 'cancelled'):
        r = run_gate({k: bad}); ck(f'gate: {k}={bad} -> rc1 naming it', r.returncode == 1 and f'{k}={bad}' in r.stdout, (r.returncode, r.stdout))
# --- executed: per-step state fidelity and the real UI-assertion step on Linux with forced conditions
CD = R + '/scripts/check-demo-state.py'
def write_states(dirp, mod=None):
    for n in range(1, 82):
        alert = n in (71, 72)
        s = dict(step=n, main='true', w=1280, h=800, sheet=str(alert).lower(), alertModel=str(alert).lower(), keyIsSheet='false',
                 sheetId=('removal-result' if alert else 'none'), sheetRows=0)
        if n == 78: s.update(sheet='true', keyIsSheet='true', sheetId='notscanned', sheetRows=3)   # the designed Not-scanned sheet: up and key, content loaded, no alert in the model
        if mod: mod(n, s)
        if s is None: continue
        open(f'{dirp}/spz-demo-state-{n}', 'w').write(' '.join(f'{k}={v}' for k, v in s.items()) + '\n')
def fidelity(mod=None, skip=None):
    t = tempfile.mkdtemp(prefix='demostate-')
    try:
        write_states(t, mod)
        if skip: os.remove(f'{t}/spz-demo-state-{skip}')
        return subprocess.run([sys.executable, CD, t, '81'], capture_output=True, text=True)
    finally: shutil.rmtree(t, ignore_errors=True)
ck('fidelity baseline: 81 healthy records, alert only at 71/72 -> rc0', fidelity().returncode == 0)
ck('fidelity: missing record for step 75 -> rc1', fidelity(skip=75).returncode == 1)
ck('fidelity: stale alert at step 80 -> rc1', fidelity(lambda n, s: s.update(sheet='true', alertModel='true') if n == 80 else None).returncode == 1)
ck('fidelity: no alert at step 71 -> rc1', fidelity(lambda n, s: s.update(sheet='false', alertModel='false') if n == 71 else None).returncode == 1)
ck('fidelity: tiny window at step 76 -> rc1', fidelity(lambda n, s: s.update(w=100) if n == 76 else None).returncode == 1)
ck('fidelity: key window is a sheet at step 79 -> rc1', fidelity(lambda n, s: s.update(keyIsSheet='true') if n == 79 else None).returncode == 1)
ck('fidelity: no main window at step 74 -> rc1', fidelity(lambda n, s: s.update(main='false') if n == 74 else None).returncode == 1)
ck('fidelity: wrong sheet identity at 78 -> rc1', fidelity(lambda n, s: s.update(sheetId='unknown') if n == 78 else None).returncode == 1)
ck('fidelity: sheet content not loaded at 78 (sheetRows=0) -> rc1', fidelity(lambda n, s: s.update(sheetRows=0) if n == 78 else None).returncode == 1)
ck('fidelity: wrong alert identity at 71 -> rc1', fidelity(lambda n, s: s.update(sheetId='unknown') if n == 71 else None).returncode == 1)
# --- static wiring: the step-13 result alert must be dismissed BEFORE mark(14) AND again after the undo (fidelity: alerts only at 71-72)
src = open(R + '/Sources/Spacelyzer/SpacelyzerApp.swift').read()
real_ck = src.find('Check.expect("real-trash-moves-only-the-selected-fixture"'); dismiss1 = src.find('model.removalMessage = nil; model.pendingRemoval = nil', real_ck); mark14 = src.find('mark(14)', real_ck)
undo_ck = src.find('Check.expect("undo-restores-the-fixture"'); dismiss2 = src.find('model.removalMessage = nil; model.pendingRemoval = nil', undo_ck); settle700 = src.find('700_000_000', undo_ck)
ck('wiring: step-13 result alert dismissed before mark(14) and again after the undo check (not execution proof; Mac pixels verify)', -1 < real_ck < dismiss1 < mark14 and -1 < undo_ck < dismiss2 < settle700, (real_ck, dismiss1, mark14, undo_ck, dismiss2))
cv = open(R + '/Sources/Spacelyzer/ContentView.swift').read()
scan_menu = cv.find('Label("Scan", systemImage: "externaldrive")'); scan_label = cv.find('.accessibilityLabel("Scan")')
ck('wiring: the icon-only Scan toolbar menu carries an accessibility label (Finding 3: unlabeled AXButton in the run dump; Mac AX tree verifies)', -1 < scan_menu < scan_label, (scan_menu, scan_label))
ck('wiring: sheet identity is OBSERVED from the attached sheet content, never from presentation intent (no DemoSheetState flag anywhere)',
   'DemoSheetState' not in cv and 'DemoSheetState' not in src, 'intent flag still referenced')
sl = src.find('static func stateLine')
body = src[sl:sl + 2200] if sl != -1 else ''
ck('wiring: the state line emits OBSERVED sheet identity (Not-scanned headline, Moved...Trash result text) and content rows (the gate requires sheetId/sheetRows; Mac state records verify)',
   sl != -1 and 'sheetId=' in body and 'sheetRows=' in body
   and 'FooterAXEvidence.inspect(attached, attachedTo: w)' in body
   and 'observedSheetIdentity(texts, complete: !observed.truncated)' in body
   and '"Not scanned"' in src[src.find('static func observedSheetIdentity'):sl]
   and 'hasPrefix("Moved ")' in src[src.find('static func observedSheetIdentity'):sl], sl)
m78 = src.find('mark(stepNumber); stepNumber += 1\n                                DemoInput.key(53)')
ck('wiring: step 78 waits for real sheet content (rows > 0, bounded) and lets the presentation settle before capture', m78 != -1 and 'contentDeadline7' in src[max(0, m78 - 3000):m78] and 'numberOfRows' in src[max(0, m78 - 3000):m78], m78)
A = [s for s in m['steps'] if s.get('id') == 'asserts'][0]['run']
def run_asserts(npass=178, shots=81, timing='', mod=None, missing_state=None, nfail=0):
    work = tempfile.mkdtemp(prefix='demoassert-'); made = []
    try:
        os.makedirs(work + '/dist'); os.symlink(R + '/scripts', work + '/scripts')
        for n in range(1, shots + 1): open(f'{work}/dist/screenshot-demo-{n}.png', 'wb').write(b'x')
        pre = {p: os.path.exists(p) for p in ['/tmp/spz-assertions.txt', '/tmp/spz-timing.txt']}
        if any(pre.values()): return None
        open('/tmp/spz-assertions.txt', 'w').write(''.join(f'PASS check{i}\n' for i in range(npass)) + ''.join(f'FAIL bad{i}\n' for i in range(nfail))); made.append('/tmp/spz-assertions.txt')
        open('/tmp/spz-timing.txt', 'w').write(timing); made.append('/tmp/spz-timing.txt')
        if any(os.path.exists(f'/tmp/spz-demo-state-{n}') for n in range(1, 82)): return None
        write_states('/tmp', mod); made += [f'/tmp/spz-demo-state-{n}' for n in range(1, 82)]
        if missing_state: os.remove(f'/tmp/spz-demo-state-{missing_state}')
        subprocess.run([sys.executable,R+'/scripts/observed-test-fixture.py',work,'/tmp'],check=True)
        made += ['/tmp/spz-demo-ready-78','/tmp/spz-capture-process-pin.json']
        # Declared source/executable fixture seams; actual observed gate runs.
        body=A.replace('"$(git rev-parse HEAD)"','sha-A').replace('"$PWD/dist-test/Spacelyzer.app/Contents/MacOS/Spacelyzer"','/app/A')
        return subprocess.run(['bash', '-e', '-c', body], cwd=work, capture_output=True, text=True)
    finally:
        for p in made:
            try: os.remove(p)
            except OSError: pass
        shutil.rmtree(work, ignore_errors=True)
base = run_asserts()
if base is None: print('NOT-RUN: /tmp/spz-* files already exist; refusing to clobber them'); sys.exit(1)
ck('UI-assertion step executed: 178 PASS, 81 shots, 81 healthy states -> rc0', base.returncode == 0, base.stdout[-300:] + base.stderr[-300:])
for name, kw in [('app not running at end', dict(timing='APP NOT RUNNING at end (crashed or exited)\n')), ('demo step timeout', dict(timing='DEMO STEP TIMEOUT: expected 73, last 72\n')), ('demo finish timeout', dict(timing='DEMO FINISH TIMEOUT: final assertions not completed\n')),
                 ('missing screenshot (80 of 81)', dict(shots=80)), ('177 results instead of 178', dict(npass=177)), ('a FAIL line among 178', dict(npass=177, nfail=1)),
                 ('missing state record 77', dict(missing_state=77)), ('stale alert at step 78', dict(mod=lambda n, s: s.update(alertModel='true') if n == 78 else None)),
                 ('intended sheet missing at 78', dict(mod=lambda n, s: s.update(sheet='false', keyIsSheet='false') if n == 78 else None)),
                 ('a sheet at 77 (no designed sheet there)', dict(mod=lambda n, s: s.update(sheet='true') if n == 77 else None))]:
    r = run_asserts(**kw); ck(f'UI-assertion step: {name} -> rc1 (not weakened)', r is not None and r.returncode == 1, None if r is None else (r.returncode, r.stdout[-200:]))
print(f'\n{len(fails)} failed'); sys.exit(1 if fails else 0)
