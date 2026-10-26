#!/usr/bin/env python3
"""Judge the in-app perf driver output (PerfDriver.swift, SPZ_CHECKS=perf). Usage: perf2-cancel-verdict.py RESDIR OUTVERDICT EXPECTED_RUNS
PASS = result.txt first line PERF-COMPLETE, exactly EXPECTED_RUNS cancel lines, and every cancel hit mid-scan (items_at_cancel below the full-scan node count from the
same run). Otherwise INCONCLUSIVE (driver incomplete / cancel not proven mid-scan) or FAIL (driver reported nothing). Latency values are listed, never gated: no owner-approved
threshold exists (the 1000 ms bar in the old readiness-verify design was a proposal, shown only as a note)."""
import re, sys
res, out, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
rd = lambda f: open(f'{res}/{f}').read() if __import__('os').path.exists(f'{res}/{f}') else None
r, p = rd('result.txt'), rd('perf.txt'); lines = []; v = 'PASS'
def put(x, why): 
    global v
    if v == 'PASS' or (v == 'INCONCLUSIVE' and x == 'FAIL'): v = x
    lines.append(why)
if r is None: put('INCONCLUSIVE', 'result.txt missing: the driver never finished (build failure, launch failure or hang)')
else:
    if r.splitlines()[0] != 'PERF-COMPLETE': put('INCONCLUSIVE', 'driver result: ' + ' | '.join(r.strip().splitlines()[:6]))
cancels = re.findall(r'^cancel\[(\d+)\] items_at_cancel=(\d+) cancel_call_ms=(\S+) cancel_to_engine_returned_ms=(\S+) cancel_to_scanning_false_ms=(\S+)', p or '', re.M)
full = re.search(r'^full_scan nodes=(\d+)', p or '', re.M)
if len(cancels) != n: put('INCONCLUSIVE', f'{len(cancels)} of {n} cancel samples recorded')
if not full: put('INCONCLUSIVE', 'full_scan nodes line missing, mid-scan cancel cannot be proven')
for i, items, call, eng, idle in cancels:
    mid = bool(full) and int(items) < int(full.group(1))
    lines.append(f'cancel[{i}]: items_at_cancel={items} of {full.group(1) if full else "?"}, cancel_call={call} ms, to_engine_returned={eng} ms, to_scanning_false={idle} ms, mid_scan={mid}')
    if not mid: put('INCONCLUSIVE', f'cancel[{i}] not proven mid-scan')
    if any(not re.fullmatch(r'\d+(\.\d+)?', x) for x in (call, eng, idle)): put('FAIL', f'cancel[{i}] has a non-numeric timing')
nums = [float(c[4]) for c in cancels if re.fullmatch(r'\d+(\.\d+)?', c[4])]
if nums: lines.append(f'cancel_to_scanning_false max={max(nums):.1f} ms (note only: the old readiness-verify design proposed <= 1000 ms; not an approved gate)')
for l in (p or '').splitlines():
    if l.startswith('full_scan'): lines.append(l)
open(out, 'w').write(v + '\n' + '\n'.join(lines) + '\n'); print(v, *lines, sep='\n')
