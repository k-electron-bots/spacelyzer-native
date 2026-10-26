#!/usr/bin/env python3
"""Per-leg isolation for the combined perf run. Usage:
  perf2-leg.py --leg NAME --out DIR --work SECONDS [--prereq NAME=OUTCOME ...] -- CMD [ARGS...]
Writes DIR/verdict.txt only through the leg itself, or an honest marker here: NOT-RUN (prerequisite not success, or not enough job time left),
INCOMPLETE (leg exceeded its own budget), FAIL (leg ended without writing a verdict). Never writes PASS. Exit code is always 0 so one leg never stops
the next; perf2-gate.py owns acceptance. Admission: SPZ_JOB_DEADLINE_EPOCH minus RESERVE must cover the leg budget."""
import os, signal, subprocess, sys, time
RESERVE = 410   # artifact upload 120 + post-step teardown 200 + margin 90 (same reserve as accuracy-only)
def decide(deadline, now, work):
    left = deadline - now - RESERVE
    return (left >= work, left)
def write(out, status, *lines):
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, 'verdict.txt'), 'w') as f: f.write(' '.join([status]) + '\n' + ''.join(l + '\n' for l in lines))
def main(argv):
    a = argv[:]; leg = out = work = None; pre = []
    while a and a[0] != '--':
        k = a.pop(0)
        if k == '--leg': leg = a.pop(0)
        elif k == '--out': out = a.pop(0)
        elif k == '--work': work = float(a.pop(0))
        elif k == '--prereq': pre.append(a.pop(0))
        else: print('bad arg', k, file=sys.stderr); return 64
    if not a or a.pop(0) != '--' or not a or not (leg and out and work): print('usage error', file=sys.stderr); return 64
    verdict = os.path.join(out, 'verdict.txt')
    if os.path.exists(verdict): os.remove(verdict)
    bad = [p for p in pre if p.split('=', 1)[1] != 'success']
    if bad: write(out, 'NOT-RUN', f'{leg}: prerequisite not success: ' + ', '.join(bad)); print('NOT-RUN', leg, bad); return 0
    dl = os.environ.get('SPZ_JOB_DEADLINE_EPOCH')
    if not dl: write(out, 'NOT-RUN', f'{leg}: SPZ_JOB_DEADLINE_EPOCH missing'); return 0
    ok, left = decide(float(dl), time.time(), work)
    if not ok: write(out, 'NOT-RUN', f'{leg}: needs {work:.0f}s of work time, only {left:.0f}s left before the {RESERVE}s reserve'); print('NOT-RUN', leg); return 0
    budget = min(work, left); t0 = time.time()
    p = subprocess.Popen(a, start_new_session=True)
    try: rc = p.wait(timeout=budget); timed_out = False
    except subprocess.TimeoutExpired:
        timed_out = True
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try: os.killpg(p.pid, sig)
            except ProcessLookupError: break
            try: p.wait(timeout=10); break
            except subprocess.TimeoutExpired: pass
        rc = -1
    took = time.time() - t0
    existing = os.path.exists(verdict)
    if timed_out: write(out, 'INCOMPLETE', f'{leg}: exceeded its {budget:.0f}s budget and was killed (partial evidence kept)' + (' ; the leg had already written a verdict, overridden by this timeout' if existing else ''))
    elif not existing: write(out, 'FAIL', f'{leg}: command exited rc={rc} without writing a verdict')
    open(os.path.join(out, 'timing.txt'), 'w').write(f'leg={leg} seconds={took:.1f} budget={budget:.0f} rc={rc} timed_out={timed_out}\n')
    print(open(verdict).read().strip().splitlines()[0], leg, f'{took:.0f}s'); return 0
if __name__ == '__main__': sys.exit(main(sys.argv[1:]))
