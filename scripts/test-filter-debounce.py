#!/usr/bin/env python3
"""Linux compile + behavior control for the REAL FilterDebounce policy in Sources/Spacelyzer/AppModel.swift (extracted verbatim), plus wiring checks on scheduleFilter.
Policy: 3x the last measured ACTIVE filter cost, floor 25 ms, cap 150 ms; unknown cost keeps 150 ms; reset on a tree swap. Not a Mac result and not a latency measurement."""
import pathlib, subprocess, os, tempfile, re
src = pathlib.Path('Sources/Spacelyzer/AppModel.swift').read_text()
a = src.index('// BEGIN pure filter debounce policy'); b = src.index('// END pure filter debounce policy'); block = src[a:b]
test = 'import Foundation\n' + block + '''
var bad = 0
func check(_ c: Bool, _ m: String) { if !c { print("FAIL " + m); bad += 1 } }
let ms: UInt64 = 1_000_000
check(FilterDebounce.delayNs(lastFilterMs: nil) == 150 * ms, "unknown cost keeps the full 150 ms")
check(FilterDebounce.delayNs(lastFilterMs: 4) == 25 * ms, "4 ms filter (200k, measured) floors at 25 ms")
check(FilterDebounce.delayNs(lastFilterMs: 0) == 25 * ms, "0 ms floors at 25 ms")
check(FilterDebounce.delayNs(lastFilterMs: 10) == 30 * ms, "10 ms -> 30 ms")
check(FilterDebounce.delayNs(lastFilterMs: 30) == 90 * ms, "30 ms -> 90 ms")
check(FilterDebounce.delayNs(lastFilterMs: 50) == 150 * ms, "50 ms reaches the cap")
check(FilterDebounce.delayNs(lastFilterMs: 57) == 150 * ms, "57 ms (1M nodes) keeps 150 ms")
check(FilterDebounce.delayNs(lastFilterMs: 5000) == 150 * ms, "huge cost capped")
check(FilterDebounce.delayNs(lastFilterMs: -1) == 150 * ms, "negative is treated as unknown")
check(FilterDebounce.delayNs(lastFilterMs: Double.nan) == 150 * ms, "NaN is treated as unknown")
check(FilterDebounce.delayNs(lastFilterMs: Double.infinity) == 150 * ms, "infinity is treated as unknown")
var prev: UInt64 = 0
var x = 0.0
while x <= 200 { let d = FilterDebounce.delayNs(lastFilterMs: x); check(d >= prev && d >= 25 * ms && d <= 150 * ms, "monotonic and bounded at \\(x)"); prev = d; x += 0.5 }
// the wait always covers at least 3 filter passes until the cap, so a filter cannot still be running when the next one starts
x = 0.0
while x < 50 { check(Double(FilterDebounce.delayNs(lastFilterMs: x)) >= x * 3 * 1e6 - 1, "wait >= 3x cost at \\(x)"); x += 0.25 }
if bad > 0 { exit(1) }
print("ok")
'''
d = tempfile.mkdtemp(); f = pathlib.Path(d) / 'main.swift'; f.write_text(test)
swift = pathlib.Path(os.environ.get('SWIFT_BIN', '/tmp/swift-6.1.2-RELEASE-ubuntu22.04/usr/bin')) / 'swiftc'
r = subprocess.run([str(swift), str(f), '-o', d + '/t'], capture_output=True, text=True); assert r.returncode == 0, r.stderr
o = subprocess.run([d + '/t'], capture_output=True, text=True)
assert o.returncode == 0 and 'ok' in o.stdout, o.stdout
# wiring
i0 = src.index('func scheduleFilter('); i1 = src.index('/// Largest-files and per-kind lists')
sf = src[i0:i1]
assert '150_000_000' not in sf, 'scheduleFilter must not hard-code the 150 ms wait'
assert 'let debounceNs = FilterDebounce.delayNs(lastFilterMs: lastActiveFilterMs)' in sf
assert 'Task.sleep(nanoseconds: debounceNs)' in sf and 'if !immediate' in sf, 'immediate runs still skip the wait'
assert sf.count('lastActiveFilterMs = ms') == 1 and 'if active { self.lastActiveFilterMs = ms }' in sf, 'only an active pass updates the cost'
assert re.search(r'tree = t\n\s*lastActiveFilterMs = nil', src), 'the cost is forgotten when the tree is replaced'
print('PASS filter debounce: real policy compiled on Linux (bounds, monotonic, 3x-cost cover, unknown keeps 150 ms); wiring checked by text (not a Mac result, not a latency measurement)')
