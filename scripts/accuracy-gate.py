#!/usr/bin/env python3
"""Accuracy-only evidence gate. Usage: accuracy-gate.py PREFLIGHT.json SCALE.json STEP=outcome...   (step outcomes: success/failure/skipped/cancelled)
Exit 0 only if every step succeeded AND the scale artifact says PASS AND unreadable-accounting was really exercised (non-root + chmod 000 enforced).
Missing/unparseable artifact, INCOMPLETE, FAIL, interrupted, leaks, or an over-deadline run are all red. Filesystem limits (case/NFC/non-UTF-8 NOT-RUN) are printed, not failures."""
import json, os, sys
def load(p):
    try: return json.load(open(p))
    except (OSError, ValueError): return None
pf, sc = load(sys.argv[1]), load(sys.argv[2]); steps = dict(a.split('=', 1) for a in sys.argv[3:]); bad = []
for k, v in steps.items():
    if v != 'success': bad.append(f'step {k}={v}')
if pf is None: bad.append('preflight artifact missing/unparseable')
elif not (pf.get('non_root') and pf.get('chmod000_enforced')): bad.append('unreadable accounting NOT exercised (root or chmod 000 not enforced): coverage claim impossible')
if sc is None: bad.append('scale artifact missing/unparseable')
else:
    if sc.get('verdict') != 'PASS': bad.append(f"scale verdict={sc.get('verdict')} failures={sc.get('failures')} incomplete={sc.get('incomplete')}")
    if sc.get('leaks'): bad.append(f"leaked trees: {sc['leaks']}")
    if sc.get('interrupted'): bad.append('interrupted')
    if sc.get('over_deadline'): bad.append('ran past its deadline')
    if not sc.get('rows') or [r['n'] for r in sc['rows']] != sorted(r['n'] for r in sc['rows']): bad.append('no rows / unexpected rows')
if pf and pf.get('notrun'): print('::notice::NOT-RUN on this runner (limits, not passes): ' + '; '.join(pf['notrun']))
if bad: print('::error::accuracy evidence failed/incomplete: ' + ' | '.join(bad)); sys.exit(1)
print('::notice::accuracy evidence complete for sizes ' + ','.join(str(r['n']) for r in sc['rows']) + '; Mac filesystem limits above were NOT exercised; no distribution proof'); sys.exit(0)
