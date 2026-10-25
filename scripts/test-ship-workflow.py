#!/usr/bin/env python3
"""Static and simulated controls for .github/workflows/ship-candidate.yml: the copied demo steps are verbatim, the new steps are ordered,
bounded, admission-guarded and gate-required, the time budget cannot overrun the 35-min job cap, and nothing can publish. Not a Mac result."""
import pathlib, re, subprocess, sys, yaml
sys.path.insert(0, 'scripts')
ship_txt = pathlib.Path('.github/workflows/ship-candidate.yml').read_text()
demo_txt = pathlib.Path('.github/workflows/demo-only.yml').read_text()
ship = yaml.safe_load(ship_txt); demo = yaml.safe_load(demo_txt)
on = ship.get(True, ship.get('on'))
assert list(on) == ['workflow_dispatch'] and not on['workflow_dispatch'], on   # dispatch only, no inputs
assert ship['permissions'] == {'contents': 'read'}
mac = ship['jobs']['macos']; steps = mac['steps']; ids = {x.get('id'): x for x in steps if x.get('id')}
assert mac['timeout-minutes'] == 35 and mac['needs'] == 'identity-guard'
# identity guard job identical to the lean workflow
assert ship['jobs']['identity-guard'] == demo['jobs']['identity-guard']
# 1. copied demo steps are verbatim
changed = ('Anchor hard', 'Prepare artifact dir', 'Typecheck the on-demand', 'Build the capture helper', 'Demo-validation evidence gate')
key = lambda x: x.get('id') or x.get('name') or x.get('uses')
bn = {key(x): x for x in steps}
n = 0
for d in demo['jobs']['macos']['steps']:
    nm = key(d)
    if (d.get('name') or '').startswith(changed): continue
    assert nm in bn and bn[nm] == d, f'step not verbatim: {nm}'; n += 1
print(f'PASS {n} demo steps are verbatim copies of demo-only.yml; only clock, helper compile and the gate differ')
# 2. order
order = [x.get('id') for x in steps]
chain = ['reset', 'ordering', 'ordering_artifact', 'ui_launch', 'v1cap', 'asserts', 'demo_artifact', 'sign', 'pkg', 'dmg_artifact', 'dmgcheck', 'csv', 'input', 'volumes', 'ship_artifact']
pos = [order.index(c) for c in chain]; assert pos == sorted(pos), list(zip(chain, pos))
assert order.index('ship_artifact') == len(steps) - 3 and 'Ship-candidate evidence gate' in steps[-2]['name']
# 3. new steps bounded, guarded, tolerant (the gate owns the verdict)
NEW = {'csv': 240, 'input': 180, 'volumes': 300, 'pkg': 420, 'dmgcheck': 180}
for i, work in NEW.items():
    st = ids[i]; assert st['continue-on-error'] is True and st['timeout-minutes'] * 60 == work, (i, st.get('timeout-minutes'))
    assert str(st['if']).startswith('${{ always()'), i
    assert f'ship-admit.py {"package" if i == "pkg" else i} {work}' in st['run'], i
    assert st['run'].count('&&') >= 1 and st['run'].index('ship-admit.py') < st['run'].index('&&') + 1
assert ids['sign']['continue-on-error'] is True
# 4. gate lists every continue-on-error id plus the hard ones
gate = steps[-2]['run']
tolerant = {x['id'] for x in steps if x.get('id') and x.get('continue-on-error') is True}
required = {'engine', 'swiftapp', 'testbuild', 'reset', 'ui_launch', 'asserts', 'v1cap', 'demo_artifact', 'ordering', 'ordering_artifact',
            'csv', 'input', 'volumes', 'sign', 'pkg', 'dmg_artifact', 'dmgcheck', 'ship_artifact'}
listed = set(re.findall(r"add (\w+) '\$\{\{ steps\.(\w+)\.outcome", gate) and [a for a, b in re.findall(r"add (\w+) '\$\{\{ steps\.(\w+)\.outcome", gate) if a == b])
assert required <= listed, required - listed
assert tolerant <= listed, tolerant - listed
print('PASS gate lists every tolerant step and every required step; new steps are admission-guarded, capped, always() and continue-on-error')
# 5. budget simulation (estimates labelled as such; the guard, not the estimate, protects the cap)
import importlib.util
spec = importlib.util.spec_from_file_location('admit', 'scripts/ship-admit.py'); adm = importlib.util.module_from_spec(spec); spec.loader.exec_module(adm)
CLOCK = 2100
def simulate(demo_end, durations):
    t = demo_end; ran = []; refused = []
    for name, cap in (('package', 420), ('dmgcheck', 180), ('csv', 240), ('input', 180), ('volumes', 300)):
        ok, left = adm.admit(CLOCK, cap, t)
        if not ok: refused.append(name); continue
        t += min(durations.get(name, cap), cap); ran.append(name)
    return t, ran, refused
t, ran, refused = simulate(1150, dict(csv=90, input=60, volumes=120, package=150, dmgcheck=90))   # ESTIMATE: demo+ordering done at 19 min (green run was 17.7 min total) plus helper compile
assert not refused and t + adm.RESERVE <= CLOCK, (t, refused)
t2, ran2, refused2 = simulate(1700, {})                      # a slow run: demo ends at 28.3 min, steps must be refused, never started late
assert refused2 and t2 + adm.RESERVE <= CLOCK, (t2, ran2, refused2)
t3, ran3, refused3 = simulate(1150, {k: c for k, c in (('package', 420), ('dmgcheck', 180), ('csv', 240), ('input', 180), ('volumes', 300))})   # every step at its cap
assert t3 + adm.RESERVE <= CLOCK and refused3, (t3, refused3)
print(f'PASS budget: estimate timeline ends ship steps at {t}s of {CLOCK}s; slow demo refuses {refused2}; every-step-at-cap refuses {refused3}; no admitted step can end inside the final {adm.RESERVE}s')
# 6. nothing can publish
low = ship_txt.lower()
for bad in ('gh release', 'softprops', 'action-gh-release', 'create-release', 'notarytool', 'altool'):
    assert bad not in low, bad
assert set(re.findall(r'secrets\.(\w+)', ship_txt)) == {'SIGNING_CERT_P12_BASE64', 'SIGNING_CERT_PASSWORD'}
for f in ('scripts/ship-ui.swift',): assert pathlib.Path(f).is_file()
for f in re.findall(r'scripts/(ship[\w.-]+)', ship_txt): assert (pathlib.Path('scripts') / f).is_file(), f
print('PASS no release, notarization, schedule or push trigger; only the two signing secrets; every referenced ship script exists')
# 7. admission script behavior (mutation: late start refused, missing deadline refused)
env = {'SPZ_JOB_DEADLINE_EPOCH': '10000', 'PATH': '/usr/bin:/bin'}
def run_admit(now, work=240, e=env): return subprocess.run([sys.executable, 'scripts/ship-admit.py', 'csv', str(work), str(now)], capture_output=True, text=True, env=e).returncode
assert run_admit(10000 - 240 - 150) == 0 and run_admit(10000 - 240 - 149) == 1 and run_admit(0, e={'PATH': '/usr/bin:/bin'}) == 1
print('PASS ship-admit.py admits at exactly work+150s remaining, refuses one second later, refuses a missing deadline')
