#!/usr/bin/env python3
"""Per-step content-fidelity check for demo captures. A PNG that exists and has colours does not prove it shows the intended
state (demo shots 72-81 in run 39843869589 were a stretched alert over a blank window). The app writes one state line per
step (/tmp/spz-demo-state-N) before the capture handshake; this checks each against what that step must be.
Usage: check-demo-state.py <dir> <last-step> [first-step]   exit 1 on any violation."""
import re, sys, os
ALERT_STEPS = {71, 72}          # the real Moved-to-Trash alert is up for these steps only
def parse(line):
    return dict(kv.split('=', 1) for kv in line.split() if '=' in kv)
def check(d, last, first=1):
    bad = []
    for n in range(first, last + 1):
        p = os.path.join(d, f'spz-demo-state-{n}')
        if not os.path.isfile(p): bad.append(f'step {n}: no state record'); continue
        s = parse(open(p).read().strip())
        if s.get('step') != str(n): bad.append(f'step {n}: record names step {s.get("step")}')
        if s.get('main') != 'True': bad.append(f'step {n}: no main (non-sheet) window')
        try:
            if int(s['w']) < 300 or int(s['h']) < 200: bad.append(f'step {n}: main window {s["w"]}x{s["h"]} is not a plausible app window')
        except Exception: bad.append(f'step {n}: unreadable size')
        want = n in ALERT_STEPS
        if (s.get('sheet') == 'True') != want or (s.get('alertModel') == 'True') != want:
            bad.append(f'step {n}: alert expected={want} sheet={s.get("sheet")} model={s.get("alertModel")}')
        if not want and s.get('keyIsSheet') == 'True': bad.append(f'step {n}: key window is a sheet')
    return bad
if __name__ == '__main__':
    bad = check(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]) if len(sys.argv) > 3 else 1)
    for b in bad: print('FIDELITY FAIL', b)
    print('demo state fidelity:', 'FAIL' if bad else 'PASS'); sys.exit(1 if bad else 0)
