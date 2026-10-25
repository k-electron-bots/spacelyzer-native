#!/usr/bin/env python3
"""Absolute-deadline admission for the ship-candidate steps. Usage: ship-admit.py <name> <work_seconds> [now]. Needs work + 150s reserve
(upload, gate, teardown) before SPZ_JOB_DEADLINE_EPOCH. Refusal exits 1, which the evidence gate counts as a failure (never as a skip)."""
import os, sys, time
RESERVE = 150
def admit(deadline, work, now): return deadline - now >= work + RESERVE, deadline - now
def main(argv):
    name, work = argv[1], float(argv[2]); now = float(argv[3]) if len(argv) > 3 else time.time()
    dl = os.environ.get('SPZ_JOB_DEADLINE_EPOCH')
    if not dl: print(f'FAIL {name}: SPZ_JOB_DEADLINE_EPOCH missing', file=sys.stderr); return 1
    ok, left = admit(float(dl), work, now)
    if not ok: print(f'FAIL {name}: INCOMPLETE: needs {work + RESERVE:.0f}s remaining, has {left:.1f}s', file=sys.stderr); return 1
    print(f'ADMIT {name}: needs {work + RESERVE:.0f}s, has {left:.1f}s'); return 0
if __name__ == '__main__': sys.exit(main(sys.argv))
