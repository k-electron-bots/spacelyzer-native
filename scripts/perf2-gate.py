#!/usr/bin/env python3
"""Final gate of the combined perf run. Usage: perf2-gate.py OUTROOT LEG[,LEG...] [STEP=outcome ...]
Reads OUTROOT/<leg>/verdict.txt (first word: PASS FAIL NOT-RUN INCOMPLETE INCONCLUSIVE). Writes OUTROOT/SUMMARY.md. Exit 0 only if every leg is PASS and every
STEP=outcome is success. A missing verdict is NOT-RUN, never PASS. No leg is optional: red legs stay visible next to the green ones."""
import os, sys
WORDS = ('PASS', 'FAIL', 'NOT-RUN', 'INCOMPLETE', 'INCONCLUSIVE')
def read(root, leg):
    try: txt = open(os.path.join(root, leg, 'verdict.txt')).read().strip().splitlines()
    except OSError: return 'NOT-RUN', ['verdict file missing (leg step never ran)']
    if not txt or txt[0].split(' ')[0] not in WORDS: return 'FAIL', ['unrecognized verdict: ' + repr(txt[:1])]
    return txt[0].split(' ')[0], txt[1:]
def main(argv):
    root, legs = argv[0], argv[1].split(','); steps = dict(a.split('=', 1) for a in argv[2:]); bad = []; rows = []
    for leg in legs:
        v, det = read(root, leg); rows.append((leg, v, det))
        if v != 'PASS': bad.append(f'{leg}={v}')
    for k, v in steps.items():
        if v != 'success': bad.append(f'step {k}={v}')
    out = ['# Combined perf run summary', '', '| leg | verdict |', '|---|---|'] + [f'| {l} | {v} |' for l, v, _ in rows] + ['']
    for l, v, det in rows: out += [f'## {l}: {v}'] + [f'- {d}' for d in det] + ['']
    out += ['steps: ' + ' '.join(f'{k}={v}' for k, v in steps.items()), 'overall: ' + ('PASS' if not bad else 'RED - ' + ', '.join(bad))]
    os.makedirs(root, exist_ok=True); open(os.path.join(root, 'SUMMARY.md'), 'w').write('\n'.join(out) + '\n'); print('\n'.join(out))
    return 0 if not bad else 1
if __name__ == '__main__': sys.exit(main(sys.argv[1:]))
