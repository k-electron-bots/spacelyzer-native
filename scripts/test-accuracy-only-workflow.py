#!/usr/bin/env python3
"""Static + executed checks for .github/workflows/accuracy-only.yml and its gate/preflight scripts (Linux; the workflow itself is NOT run here)."""
import json, os, re, subprocess, sys, tempfile
try: import yaml
except ImportError: print('FAIL pyyaml missing'); sys.exit(1)
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'); W = R + '/.github/workflows/accuracy-only.yml'; S = R + '/.github/workflows/scale-only.yml'
fails = []
def ck(n, ok, d=''):
    print(('ok   ' if ok else 'FAIL ') + n + ('' if ok else ' :: ' + str(d))); (ok or fails.append(n))
txt = open(W).read(); d = yaml.safe_load(txt); on = d.get('on', d.get(True))
ck('dispatch-only, no inputs, no schedule/push/pr', on == {'workflow_dispatch': None}, on)
ck('top-level permissions contents:read only', d['permissions'] == {'contents': 'read'}, d['permissions'])
ck('no write permission, secret, token, release, signing or packaging anywhere', not re.search(r'(?i)contents:\s*write|secrets\.|GITHUB_TOKEN|gh release|upload-release|codesign|notarytool|\.dmg|package-dmg|sign-setup|xcodebuild|swift build|build-test-app|build-engine\.sh|run-scale-check|make_fixtures|screencapture', re.sub(r'(?m)^\s*#.*$', '', txt)))
ck('jobs are exactly identity-guard and macos; macos needs identity-guard', set(d['jobs']) == {'identity-guard', 'macos'} and d['jobs']['macos']['needs'] == 'identity-guard')
def block(t): i = t.index('  identity-guard:'); return t[i:t.index('  macos:')]
ck('identity-guard job text is byte-identical to scale-only.yml', block(txt) == block(open(S).read()))
m = d['jobs']['macos']; ck('macos runner with a 35 min job cap', m['runs-on'] == 'macos-latest' and m['timeout-minutes'] == 35)
uses = sorted({s['uses'] for s in m['steps'] if 'uses' in s}); ck('only checkout@v4 and upload-artifact@v4', uses == ['actions/checkout@v4', 'actions/upload-artifact@v4'], uses)
ck('checkout does not persist credentials', any(s.get('uses') == 'actions/checkout@v4' and s.get('with', {}).get('persist-credentials') is False for s in m['steps']))
ids = {s.get('id'): s for s in m['steps']}
ck('spz-only build, locked, no universal/Swift', 'cargo build --release --locked -p spacelyzer-engine --bin spz' in ids['build']['run'] and 'swift' not in ids['build']['run'].lower())
ck('controls and accuracy steps are continue-on-error so artifacts and the gate always run', ids['controls'].get('continue-on-error') is True and ids['accuracy'].get('continue-on-error') is True)
ck('upload and gate run always', all(s.get('if') == '${{ always() }}' for s in m['steps'] if s.get('id') == 'acc_artifact' or s.get('name', '').startswith('Accuracy-only evidence gate')))
gate = [s for s in m['steps'] if s.get('name', '').startswith('Accuracy-only evidence gate')][0]['run']
ck('gate receives every step outcome', all(f"{k}='${{{{ steps.{k if k != 'artifact' else 'acc_artifact'}.outcome }}}}'" in gate for k in ('build', 'preflight', 'controls', 'accuracy', 'artifact')), gate)
pre = [s for s in m['steps'] if s.get('name', '').startswith('Prepare artifact')][0]['run']; ck('work deadline = job - 410 (120 artifact + 200 teardown + 90 margin)', 'SPZ_JOB_DEADLINE_EPOCH - 410' in pre and 120 + 200 + 90 == 410)
anc = m['steps'][0]['run']; ck('job clock anchored 2100s (35 min) before checkout', '+ 2100' in anc)
acc = ids['accuracy']['run']; ck('accuracy deadline is remaining work budget capped at 1200, with the 120s cleanup reserve, sizes 1k/10k/100k', '-gt 1200 ] && left=1200' in acc and '--cleanup-reserve-seconds 120' in acc and '--sizes 1000,10000,100000' in acc and '--deadline-seconds "$left"' in acc)
ck('accuracy step timeout covers its deadline', ids['accuracy']['timeout-minutes'] * 60 >= 1200)
ck('accuracy is bounded by the shared work epoch (1690s), not only its step cap; controls capped at 8 min', (2100 - 410) >= 1200 and ids['controls']['timeout-minutes'] == 8)
ck('controls keep BOTH suites running and logged', 'rc=1' in ids['controls']['run'] and ids['controls']['run'].count('tee') == 2)
ck('accuracy step captures its exit code before tail (set -e safe)', '|| rc=$?' in acc)
ck('referenced scripts exist', all(os.path.exists(R + '/scripts/' + x) for x in ('run-with-deadline.py', 'accuracy-preflight.py', 'accuracy-gate.py', 'accuracy-scale.py', 'independent-size-oracle.py', 'test-accuracy-controls.py', 'test-accuracy-scale-controls.py', 'tamper-dump.py')))
try:
    ch = subprocess.run(['git', '-C', R, 'diff', '--name-only', '6a476eb88aeeb019f891ffeffaf91f551be66e78', '--', '.github/workflows'], capture_output=True, text=True).stdout.split()
    ck('no other workflow changed vs reviewed base (others stay as they are)', set(ch) <= {'.github/workflows/accuracy-only.yml'}, ch)
except OSError: print('NOT-RUN git unavailable')
# executed: preflight and gate failure matrix
tmp = tempfile.mkdtemp(); pf = tmp + '/pf.json'
r = subprocess.run([sys.executable, R + '/scripts/accuracy-preflight.py', pf], capture_output=True, text=True); P = json.load(open(pf))
ck('preflight runs and records capabilities', r.returncode == 0 and all(k in P for k in ('non_root', 'chmod000_enforced', 'case_sensitive', 'nfc_nfd_distinct', 'non_utf8_names', 'unix_socket', 'tmp_free_mib')), r.stderr[-200:])
good_pf = dict(non_root=True, chmod000_enforced=True, notrun=[]); good_sc = dict(verdict='PASS', failures=[], incomplete=[], leaks=[], interrupted=False, over_deadline=False, rows=[dict(n=1000), dict(n=10000), dict(n=100000)])
ok_steps = ['build=success', 'preflight=success', 'controls=success', 'accuracy=success', 'artifact=success']
def gate(pfd, scd, steps=ok_steps):
    a = tmp + '/a.json'; b = tmp + '/b.json'
    for p, v in ((a, pfd), (b, scd)):
        if v is None:
            if os.path.exists(p): os.unlink(p)
        else: json.dump(v, open(p, 'w'))
    return subprocess.run([sys.executable, R + '/scripts/accuracy-gate.py', a, b, *steps], capture_output=True, text=True)
ck('gate PASS: all success + PASS + exercised unreadable', gate(good_pf, good_sc).returncode == 0)
ck('gate passes with only filesystem NOT-RUN limits, and prints them', (lambda g: g.returncode == 0 and 'NOT-RUN' in g.stdout)(gate(dict(good_pf, notrun=['filesystem is case-insensitive']), good_sc)))
def red(name, pfd, scd, steps=ok_steps): g = gate(pfd, scd, steps); ck(f'gate RED: {name}', g.returncode == 1 and '::error::' in g.stdout, (g.returncode, g.stdout[-200:]))
for st in range(5): red(f'step {ok_steps[st].split("=")[0]} failed', good_pf, good_sc, [x if i != st else x.split('=')[0] + '=failure' for i, x in enumerate(ok_steps)])
red('step skipped', good_pf, good_sc, ['build=success', 'preflight=success', 'controls=skipped', 'accuracy=success', 'artifact=success'])
red('preflight artifact missing', None, good_sc); red('scale artifact missing', good_pf, None)
red('running as root', dict(good_pf, non_root=False), good_sc); red('chmod 000 not enforced', dict(good_pf, chmod000_enforced=False), good_sc)
for k, v in (('verdict', 'FAIL'), ('verdict', 'INCOMPLETE'), ('leaks', ['x']), ('interrupted', True), ('over_deadline', True), ('rows', [])): red(f'scale {k}={v}', good_pf, dict(good_sc, **{k: v}))
open(tmp + '/b.json', 'w').write('{not json'); g = subprocess.run([sys.executable, R + '/scripts/accuracy-gate.py', tmp + '/a.json', tmp + '/b.json', *ok_steps], capture_output=True, text=True); ck('gate RED: unparseable scale artifact', g.returncode == 1)
sys.exit(1 if fails else 0)
