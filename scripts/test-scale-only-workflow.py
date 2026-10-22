#!/usr/bin/env python3
"""Structural contract for .github/workflows/scale-only.yml (Linux, static: NOT execution evidence)."""
import yaml, re, os
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
txt = open(R + '/.github/workflows/scale-only.yml').read()
d = yaml.safe_load(txt); ci = yaml.safe_load(open(R + '/.github/workflows/ci.yml'))
on = d[True]; fails = []
def ck(n, ok):
    print(('ok   ' if ok else 'FAIL ') + n); (ok or fails.append(n))
ck('dispatch-only, no inputs, no schedule/push/PR/tag', on == {'workflow_dispatch': None})
ck('read-only token', d['permissions'] == {'contents': 'read'})
ck('identity-guard job identical to ci.yml', d['jobs']['identity-guard'] == ci['jobs']['identity-guard'])
m = d['jobs']['macos']; st = m['steps']
ck('macos needs identity-guard, 35 min cap, macos runner', m['needs'] == 'identity-guard' and m['timeout-minutes'] == 35 and m['runs-on'] == 'macos-latest')
ck('job clock anchored first, 2100s', 'SPZ_JOB_DEADLINE_EPOCH' in st[0]['run'] and '2100' in st[0]['run'])
ck('work deadline holds back 1400s', 'JOB_DEADLINE_EPOCH - 1400' in txt and 1000 + 120 + 190 + 90 == 1400)
code = '\n'.join(str(x.get('run', '')) + ' ' + str(x.get('uses', '')) for x in st).lower()
for bad in ('secrets.', 'release', 'dmg', 'sign-setup', 'docs-capture', 'spz_demo', 'package'):
    ck(f'no {bad} in any step command', bad not in code)
ck('no secrets anywhere in the file', 'secrets.' not in txt and 'contents: write' not in txt)
by = {s.get('id'): s for s in st if s.get('id')}
ck('scale args: 1000s budget, max 1200, teardown 190, reserve 120', all(x in by['scale']['run'] for x in ('--budget-seconds 1000', '--max-budget-seconds 1200', '--teardown-seconds 190', '--artifact-reserve-seconds 120')))
ck('scale and gate run only after a successful test build; neither can retry', 'testbuild.outcome' in by['scale']['if'] and 'testbuild.outcome' in by['gate']['if'] and 'retry' not in txt.lower().replace('no retry', ''))
ck('scale step timeout 19 min <= job cap', by['scale']['timeout-minutes'] == 19 and by['scale']['continue-on-error'] is True)
ck('artifact upload always, error if empty', by['scale_artifact']['if'].strip() == '${{ always() }}' and by['scale_artifact']['with']['if-no-files-found'] == 'error')
gate = [s for s in st if s.get('name', '').startswith('Scale-only evidence gate')][0]
ck('evidence gate always and covers engine/testbuild/gate/scale/artifact', all(f"add {k}" in gate['run'] for k in ('engine', 'testbuild', 'gate', 'scale', 'scale_artifact')) and 'always()' in gate['if'])
ck('cargo gate is the ci-checks ci_scan_gate test', '--features ci-checks --test ci_scan_gate' in by['gate']['run'])
ck('81 demos / ui assertions not included', 'screenshot-demo' not in txt and 'ui_launch' not in txt)
raise SystemExit(1 if fails else 0)
