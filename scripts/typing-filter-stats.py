#!/usr/bin/env python3
"""Summarize one typing run: bench per-key jsonl (t0_ns, footer_ms) + the app's SPZ_TIMING log (filter-key / filter-pass-start / filter-pass-end / filter-publish).
Splits each key's latency into: delivery (t0 -> app saw the edit), wait (edit -> engine start), engine, publish (engine end -> published), and the rest of footer_ms
(= publish -> AX-visible, bench side). Also reports the app's coalescer counters (overlaps and stale_published must be 0). Reporting only: no verdict, no thresholds.
Keys are matched to the app's edits by order of time (first filter-key at or after t0_ns), never by guessing. Unmatched keys are counted."""
import json, re, sys, statistics as st

def pct(v, q):
    if not v: return None
    v = sorted(v); return round(v[min(len(v) - 1, int(round(q * (len(v) - 1))))], 2)

def summarize(keys, lines):
    edits, starts, ends, pubs, counters = [], {}, {}, {}, None
    for l in lines:
        m = re.match(r'filter-(key|pass-start|pass-end|publish) gen=(\d+) at_ns=(\d+)(.*)', l.strip())
        if not m: continue
        kind, gen, at, rest = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4)
        if kind == 'key': edits.append((at, gen))
        elif kind == 'pass-start': starts[gen] = at
        elif kind == 'pass-end': ends[gen] = at
        else:
            pubs[gen] = at
            c = dict(re.findall(r'(\w+)=(\d+)', rest)); counters = {k: int(v) for k, v in c.items()}
    edits.sort()
    cols = {k: [] for k in ('delivery_ms', 'wait_ms', 'engine_ms', 'publish_ms', 'footer_after_publish_ms', 'footer_ms')}
    unmatched = skipped = 0
    j = 0
    for k in sorted(keys, key=lambda e: e['t0_ns']):
        while j < len(edits) and edits[j][0] < k['t0_ns']: j += 1
        if j >= len(edits): unmatched += 1; continue
        at, gen = edits[j]; j += 1
        if gen not in pubs or gen not in starts or gen not in ends: skipped += 1; continue
        if k.get('footer_ms', -1) < 0: unmatched += 1; continue
        cols['delivery_ms'].append((at - k['t0_ns']) / 1e6)
        cols['wait_ms'].append((starts[gen] - at) / 1e6)
        cols['engine_ms'].append((ends[gen] - starts[gen]) / 1e6)
        cols['publish_ms'].append((pubs[gen] - ends[gen]) / 1e6)
        cols['footer_after_publish_ms'].append(k['footer_ms'] - (pubs[gen] - k['t0_ns']) / 1e6)
        cols['footer_ms'].append(k['footer_ms'])
    out = {c: {'n': len(v), 'p50': pct(v, .5), 'p95': pct(v, .95)} for c, v in cols.items()}
    return {'matched_keys': len(cols['footer_ms']), 'unmatched_keys': unmatched, 'keys_without_complete_app_stamps': skipped,
            'app_edits': len(edits), 'counters_last': counters, 'stages': out,
            'note': 'reporting only; stage split assumes bench and app share the mach-uptime clock; keys matched by order'}

if __name__ == '__main__':
    keys = []
    for l in open(sys.argv[1]):
        try: d = json.loads(l)
        except ValueError: continue
        if d.get('event') == 'key' and 't0_ns' in d: keys.append(d)
    lines = open(sys.argv[2]).read().splitlines()
    print(json.dumps(summarize(keys, lines), indent=1))
