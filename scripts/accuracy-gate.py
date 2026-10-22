#!/usr/bin/env python3
"""Accuracy-only evidence gate. Usage: accuracy-gate.py PREFLIGHT.json SCALE.json STEP=outcome...   (step outcomes: success/failure/skipped/cancelled)
Exit 0 only if every step succeeded AND the scale artifact says PASS AND unreadable-accounting was really exercised (non-root + chmod 000 enforced).
Missing/unparseable artifact, INCOMPLETE, FAIL, interrupted, leaks, or an over-deadline run are all red. Filesystem limits (case/NFC/non-UTF-8 NOT-RUN) are printed, not failures."""
import json, os, sys
def load(p):
    try: return json.load(open(p))
    except (OSError, ValueError): return None
pf, sc = load(sys.argv[1]), load(sys.argv[2]); args = [a for a in sys.argv[3:] if not a.startswith('expect-platform=')]; expect = [a.split('=', 1)[1] for a in sys.argv[3:] if a.startswith('expect-platform=')]
steps = dict(a.split('=', 1) for a in args); bad = []
WANT = [1000, 10000, 100000]
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
    rows = sc.get('rows') or []
    if [r.get('n') for r in rows] != WANT: bad.append(f"rows must be exactly sizes {WANT}, got {[r.get('n') for r in rows]}")
    for r in rows:
        for v in ('links', 'nolinks'):
            x = r.get(v)
            if not isinstance(x, dict): bad.append(f"{r.get('n')}/{v}: variant missing"); continue
            ch = x.get('checks') or {}
            need = ('items_vs_construction', 'bytes_oracle_vs_default', 'bytes_oracle_vs_portable', 'symlinks', 'extra_hardlinks', 'unreadable', 'skipped_count_parsed_and_equal', 'verdict_agree')
            if sorted(ch) != sorted(need) or not all(ch[k] is True for k in need): bad.append(f"{r.get('n')}/{v}: checks missing or false {ch}")
            pn = x.get('per_node') or {}
            if sorted(pn) != ['default', 'portable']: bad.append(f"{r.get('n')}/{v}: backend legs must be exactly default+portable, got {sorted(pn)}"); continue
            for be, leg in pn.items():
                if leg.get('diffs') != 0 or not isinstance(leg.get('nodes'), int) or leg['nodes'] < 1 or not leg.get('scope'): bad.append(f"{r.get('n')}/{v}/{be}: per-node diffs={leg.get('diffs')} nodes={leg.get('nodes')} scope={'present' if leg.get('scope') else 'missing'}")
                want_scope = 'full' if v == 'nolinks' else 'path set'
                if leg.get('scope') and not leg['scope'].startswith(want_scope): bad.append(f"{r.get('n')}/{v}/{be}: wrong comparison scope {leg['scope'][:40]!r}")
                exp = (x.get('construct') or {}).get('planted_unreadable_dirs')
                sk = leg.get('skips')
                if not isinstance(sk, list) or exp is None or len(sk) != exp or any(not (isinstance(q, list) and len(q) == 2 and q[0] == 'PermissionDenied') for q in sk): bad.append(f"{r.get('n')}/{v}/{be}: skips must be exactly the {exp} planted PermissionDenied, got {sk}")
    if expect and not (isinstance(sc.get('platform'), str) and all(e in sc['platform'] for e in expect)): bad.append(f"platform {sc.get('platform')!r} does not contain {expect}")
    if pf and sc.get('platform') != pf.get('platform'): bad.append(f"platform differs between preflight ({pf.get('platform')!r}) and scale ({sc.get('platform')!r})")
    if pf and sc.get('uid') != pf.get('uid'): bad.append(f"uid differs between preflight ({pf.get('uid')}) and scale ({sc.get('uid')})")
if pf and pf.get('notrun'): print('::notice::NOT-RUN on this runner (limits, not passes): ' + '; '.join(pf['notrun']))
if bad: print('::error::accuracy evidence failed/incomplete: ' + ' | '.join(bad)); sys.exit(1)
print('::notice::accuracy evidence complete for sizes ' + ','.join(str(r['n']) for r in sc['rows']) + '; Mac filesystem limits above were NOT exercised; no distribution proof'); sys.exit(0)
