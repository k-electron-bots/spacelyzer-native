#!/usr/bin/env python3
"""Linux compile + behavior control for the REAL pure milestone logic in Sources/Spacelyzer/PerfDriver.swift (PerfState / PerfMilestones), extracted verbatim.
Run 40249523646 regression: state already non-empty from launch must NOT produce durations; real post-engine changes do; a genuine pre-engine change is still flagged
(INCOMPLETE upstream); never-changing is 'never'. Not a Mac result."""
import os, pathlib, subprocess, tempfile
src = pathlib.Path('Sources/Spacelyzer/PerfDriver.swift').read_text()
a = src.index('struct PerfState'); b = src.index('@MainActor enum PerfDriver'); block = src[a:b]
swift = pathlib.Path(os.environ.get('SWIFT_BIN', '/tmp/swift-6.1.2-RELEASE-ubuntu22.04/usr/bin')) / 'swiftc'
prog = 'import Foundation\n' + block + '''
var bad: [String] = []
func check(_ c: Bool, _ m: String) { if !c { bad.append(m) } }
let empty = PerfState(rows: 0, outline: nil, derived: nil, layout: nil)
let stale = PerfState(rows: 7, outline: 3, derived: 3, layout: 3)
// stale-at-start: unchanged state is not a milestone; rows are reported as a note, never a duration
for n in ["outline_rows_nonempty", "outline_version", "derived_version", "layout_version"] {
    check(PerfMilestones.observed(n, state: stale, base: stale) != true, "stale unchanged \\(n) must not count as observed")
    check(PerfMilestones.staleAtStart(n, base: stale), "\\(n) must be flagged stale")
    check(!PerfMilestones.staleAtStart(n, base: empty), "\\(n) not stale from an empty base")
}
check(PerfMilestones.observed("outline_rows_nonempty", state: stale, base: stale) == nil, "rows with stale base are unobservable (nil)")
// real change after start
let after = PerfState(rows: 9, outline: 4, derived: 4, layout: 4)
for n in ["outline_version", "derived_version", "layout_version"] { check(PerfMilestones.observed(n, state: after, base: stale) == true, "changed \\(n) observed") }
check(PerfMilestones.observed("outline_rows_nonempty", state: after, base: empty) == true, "rows appearing from empty observed")
check(PerfMilestones.observed("outline_rows_nonempty", state: empty, base: empty) == false, "empty stays unobserved")
check(PerfMilestones.observed("layout_version", state: empty, base: empty) == false, "nil->nil unobserved")
check(PerfMilestones.observed("layout_version", state: PerfState(rows: 0, outline: nil, derived: nil, layout: 1), base: empty) == true, "nil->value observed")
// ordering
check(PerfMilestones.classify(seen: 150, engine: 100) == .after(50), "after engine: duration")
check(PerfMilestones.classify(seen: 100, engine: 100) == .after(0), "equal counts as after")
check(PerfMilestones.classify(seen: 90, engine: 100) == .beforeEngine, "genuine pre-engine change stays an anomaly")
check(PerfMilestones.classify(seen: nil, engine: 100) == .never, "never observed")
print(bad.isEmpty ? "OK" : "BAD " + bad.joined(separator: "; "))
'''
t = pathlib.Path(tempfile.mkdtemp()); (t / 'm.swift').write_text(prog)
r = subprocess.run([str(swift), '-swift-version', '5', str(t / 'm.swift'), '-o', str(t / 'm')], capture_output=True, text=True); assert r.returncode == 0, r.stderr[-1500:]
o = subprocess.run([str(t / 'm')], capture_output=True, text=True).stdout.strip(); assert o == 'OK', o
print('PASS PerfDriver milestone logic: stale launch state yields notes not durations; real changes yield durations; pre-engine change stays anomalous (pure logic compiled on Linux, not a Mac result)')
