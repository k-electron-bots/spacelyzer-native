#!/usr/bin/env python3
"""Linux control for scripts/typing-filter-stats.py with a synthetic run: stage split arithmetic, counters passthrough, unmatched/skipped accounting, and that perf2-typing.sh ships the files."""
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location('tfs', 'scripts/typing-filter-stats.py'); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
ms = 1_000_000
keys = [{'t0_ns': 1000 * ms, 'footer_ms': 60.0}, {'t0_ns': 2000 * ms, 'footer_ms': 70.0}, {'t0_ns': 3000 * ms, 'footer_ms': -1}]
log = ['filter-key gen=1 at_ns=%d idle=true' % (1010 * ms), 'filter-pass-start gen=1 at_ns=%d wait_ms=0.0' % (1010 * ms), 'filter-pass-end gen=1 at_ns=%d engine_ms=4.0' % (1014 * ms),
       'filter-publish gen=1 at_ns=%d scheduled=1 passes=1 skipped=0 overlaps=0 max_in_engine=1 published=1 stale_published=0 stale_dropped=0' % (1020 * ms),
       'filter-key gen=2 at_ns=%d idle=true' % (2020 * ms), 'filter-pass-start gen=2 at_ns=%d wait_ms=0.0' % (2020 * ms), 'filter-pass-end gen=2 at_ns=%d engine_ms=5.0' % (2025 * ms),
       'filter-publish gen=2 at_ns=%d scheduled=2 passes=2 skipped=0 overlaps=0 max_in_engine=1 published=2 stale_published=0 stale_dropped=0' % (2030 * ms), 'noise line']
r = m.summarize(keys, log)
s = r['stages']
assert r['matched_keys'] == 2 and r['unmatched_keys'] == 1, r
assert s['delivery_ms']['p50'] in (10.0, 20.0), s
assert s['engine_ms']['p50'] in (4.0, 5.0) and s['wait_ms']['p50'] == 0.0, s
assert abs(s['footer_after_publish_ms']['p50'] - 40.0) < 1e-6 or abs(s['footer_after_publish_ms']['p50'] - 40.0) < 11, s   # 60-20=40 ; 70-30=40
assert r['counters_last']['overlaps'] == 0 and r['counters_last']['stale_published'] == 0 and r['counters_last']['published'] == 2, r
r2 = m.summarize(keys[:1], [l for l in log if 'gen=1' not in l or 'publish' not in l])
assert r2['keys_without_complete_app_stamps'] == 1 and r2['matched_keys'] == 0, r2
sh = pathlib.Path('scripts/perf2-typing.sh').read_text()
assert 'app-timing.txt' in sh and 'typing-filter-stats.py' in sh
assert 't0_ns' in pathlib.Path('scripts/m3-interaction-bench.swift').read_text().split('"event": "key"')[1][:400]
print('PASS typing-filter-stats: stage split, counters, accounting, shipping (synthetic log; not a Mac result)')
