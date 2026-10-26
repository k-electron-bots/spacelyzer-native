#!/usr/bin/env python3
"""Accuracy leg: preflight, isolated tamper controls (oracle + scale harness), scaled accuracy 1k/10k/100k (default AND portable engine legs), then the
existing accuracy-gate.py as judge. Usage: perf2-accuracy.py --spz BIN --out DIR --budget SECONDS [--platform macOS]
Every stage always runs (a red control does NOT hide the numbers, and the gate sees the control as failed). Verdict PASS only when accuracy-gate.py exits 0."""
import argparse, os, subprocess, sys, time
ap = argparse.ArgumentParser(); ap.add_argument('--spz', required=True); ap.add_argument('--out', required=True); ap.add_argument('--budget', type=float, required=True)
ap.add_argument('--platform', default='macOS'); ap.add_argument('--scripts', default=os.path.dirname(os.path.abspath(__file__)))
a = ap.parse_args(); t0 = time.time(); os.makedirs(a.out, exist_ok=True); S = a.scripts
def run(name, argv, log, env=None, timeout=None):
    with open(os.path.join(a.out, log), 'w') as f:
        try: rc = subprocess.run(argv, stdout=f, stderr=subprocess.STDOUT, env=env, timeout=timeout).returncode
        except subprocess.TimeoutExpired: rc = 124
    print(f'{name}: rc={rc}', flush=True); return rc
left = lambda: a.budget - (time.time() - t0)
env = dict(os.environ, SPZ_BIN=os.path.abspath(a.spz))
pre = run('preflight', [sys.executable, f'{S}/accuracy-preflight.py', os.path.join(a.out, 'preflight.json')], 'preflight.log', timeout=60)
c1 = run('controls-oracle', [sys.executable, f'{S}/test-accuracy-controls.py'], 'controls-oracle.log', env, timeout=max(30, min(120, left() - 200)))
c2 = run('controls-scale', [sys.executable, f'{S}/test-accuracy-scale-controls.py'], 'controls-scale.log', env, timeout=max(30, min(120, left() - 150)))
dl = int(max(60, left() - 40))
acc = run('accuracy-scale', [sys.executable, f'{S}/accuracy-scale.py', '--spz', a.spz, '--sizes', '1000,10000,100000', '--deadline-seconds', str(dl), '--cleanup-reserve-seconds', '60',
          '--out', os.path.join(a.out, 'accuracy-scale.json'), '--evidence-dir', os.path.join(a.out, 'evidence')], 'accuracy-scale.log', timeout=dl + 30)
g = subprocess.run([sys.executable, f'{S}/accuracy-gate.py', os.path.join(a.out, 'preflight.json'), os.path.join(a.out, 'accuracy-scale.json'),
     f'preflight={"success" if pre == 0 else "failure"}', f'controls={"success" if c1 == 0 and c2 == 0 else "failure"}', f'accuracy={"success" if acc == 0 else "failure"}', f'expect-platform={a.platform}'],
     capture_output=True, text=True)
open(os.path.join(a.out, 'accuracy-gate.txt'), 'w').write(g.stdout + g.stderr)
tail = [l for l in (g.stdout + g.stderr).strip().splitlines() if l][-12:]
open(os.path.join(a.out, 'verdict.txt'), 'w').write(('PASS' if g.returncode == 0 else 'FAIL') + '\n' + f'preflight rc={pre}, controls rc={c1}/{c2}, accuracy-scale rc={acc}, gate rc={g.returncode}, seconds={time.time() - t0:.0f}\n' + '\n'.join(tail) + '\n')
sys.exit(0)
