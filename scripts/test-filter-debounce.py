#!/usr/bin/env python3
"""Linux compile + behavior control for the REAL FilterDebounce policy in Sources/Spacelyzer/AppModel.swift (extracted verbatim), plus wiring checks on scheduleFilter.
Policy: idle = 0 wait (leading edge); during a burst 3x the last measured ACTIVE filter cost, floor 25 ms, cap 150 ms, unknown cost 150 ms; reset on a tree swap.
Coalescer: the REAL FilterCoalescer.start is driven by a scheduler model: no two passes overlap, a superseded edit never reaches the engine, the newest always runs and publishes, nothing stale publishes. Not a Mac result and not a latency measurement."""
import pathlib, subprocess, os, tempfile, re
src = pathlib.Path('Sources/Spacelyzer/AppModel.swift').read_text()
a = src.index('// BEGIN pure filter debounce policy'); b = src.index('// END pure filter coalescer'); block = src[a:b]
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

setvbuf(stdout, nil, _IOLBF, 0)
// ---- idle / leading edge ----
check(FilterDebounce.delayNs(lastFilterMs: nil, idle: true) == 0, "idle starts at once even with unknown cost")
check(FilterDebounce.delayNs(lastFilterMs: 4, idle: true) == 0, "idle starts at once")
check(FilterDebounce.delayNs(lastFilterMs: 4, idle: false) == 25 * ms, "burst keeps the cost-scaled wait")
check(FilterDebounce.delayNs(lastFilterMs: 4) == 25 * ms, "default is burst")

// ---- coalescer driven by a scheduler model that mirrors scheduleFilter: cancel predecessor, bump generation, start ----
final class Model: @unchecked Sendable {
    let lock = NSLock()
    var task: Task<Void, Never>?
    let stats = FilterPassStats()
    var generation = 0
    var running = 0, maxRunning = 0
    var started: [Int] = [], published: [Int] = []
    var startTimes: [Int: Double] = [:], endTimes: [Int: Double] = [:]
    let t0 = Date()
    func now() -> Double { Date().timeIntervalSince(t0) * 1000 }
    func schedule(delayNs: UInt64, engineMs: UInt64) {
        let pred = task; pred?.cancel()
        lock.lock(); generation += 1; let g = generation; lock.unlock(); stats.edit()
        task = FilterCoalescer.start(after: pred, delayNs: delayNs) { [self] in
            lock.lock(); running += 1; maxRunning = max(maxRunning, running); started.append(g); startTimes[g] = now(); lock.unlock(); stats.passBegin()
            await Task.detached { try? await Task.sleep(nanoseconds: engineMs * 1_000_000) }.value   // the engine call: not interruptible (a detached sleep ignores the cancel of its awaiter)
            lock.lock(); running -= 1; endTimes[g] = now(); lock.unlock(); stats.passEnd()
            if Task.isCancelled { stats.dropped(); return }
            lock.lock(); let cur = generation; lock.unlock()
            guard cur == g else { stats.dropped(); return }
            lock.lock(); published.append(g); lock.unlock(); stats.publish(generation: UInt64(g), latest: UInt64(cur))
        }
    }
    func drain() async { await task?.value }
}
func sleepMs(_ n: UInt64) async { try? await Task.sleep(nanoseconds: n * 1_000_000) }

// A: idle edit with delay 0 starts promptly and publishes
do {
    let m = Model(); m.schedule(delayNs: 0, engineMs: 20); await sleepMs(8)
    check(m.started == [1], "A: an idle edit starts at once")
    await m.drain(); check(m.published == [1], "A: and publishes")
}
// B: burst of 12 edits 5 ms apart, 30 ms engine, 25 ms wait: no overlap, newest runs and publishes, intermediates skipped, nothing stale published
do {
    let m = Model()
    for _ in 0..<12 { m.schedule(delayNs: 25_000_000, engineMs: 30); await sleepMs(5) }
    await m.drain()
    check(m.maxRunning == 1, "B: engine passes never overlap (max \(m.maxRunning))")
    check(m.started.last == 12 && m.published == [12], "B: only the newest publishes (published \(m.published))")
    check(m.started.count < 12, "B: intermediate edits were coalesced (started \(m.started))")
}
// C: superseded during its wait never reaches the engine
do {
    let m = Model(); m.schedule(delayNs: 150_000_000, engineMs: 20); await sleepMs(10); m.schedule(delayNs: 0, engineMs: 20)
    await m.drain()
    check(m.started == [2] && m.published == [2], "C: the superseded edit never ran (started \(m.started))")
    check((m.endTimes[2] ?? 1e9) < 100, "C: the cancelled sleeper did not delay the newest (\(m.endTimes[2] ?? -1) ms)")
}
// D: a new edit while a pass is inside the engine waits for it, then runs; the old one does not publish
do {
    let m = Model(); m.schedule(delayNs: 0, engineMs: 60); await sleepMs(15); m.schedule(delayNs: 0, engineMs: 20)
    await m.drain()
    check(m.maxRunning == 1, "D: no overlap")
    check((m.startTimes[2] ?? -1) >= (m.endTimes[1] ?? 1e9) - 1, "D: the newest starts after the running pass finishes")
    check(m.published == [2], "D: only the newest publishes (published \(m.published))")
}
// E: two edits queue behind a running pass (delay 0): the middle one is superseded while waiting and never reaches the engine
do {
    let m = Model(); m.schedule(delayNs: 0, engineMs: 60); await sleepMs(10); m.schedule(delayNs: 0, engineMs: 20); await sleepMs(5); m.schedule(delayNs: 0, engineMs: 20)
    await m.drain()
    check(m.started == [1, 3] && m.published == [3] && m.maxRunning == 1, "E: queued middle edit skipped (started \(m.started) published \(m.published))")
}
// F: the verification counters themselves
do {
    let t = FilterPassStats()
    t.edit(); t.edit(); t.passBegin(); t.passBegin(); t.passEnd(); t.passEnd()
    check(t.overlaps == 1 && t.maxInEngine == 2 && t.passes == 2 && t.scheduled == 2, "F: an overlap is counted (\(t.summary))")
    t.publish(generation: 1, latest: 2); t.publish(generation: 2, latest: 2); t.dropped()
    check(t.stalePublished == 1 && t.published == 2 && t.staleDropped == 1, "F: a stale publish is counted (\(t.summary))")
    let u = FilterPassStats(); u.passBegin(); u.passEnd(); u.passBegin(); u.passEnd()
    check(u.overlaps == 0 && u.maxInEngine == 1, "F: sequential passes are not overlaps")
}
// G: the counters, fed by the real coalescer, read clean in B/D/E-style runs
do {
    let m = Model(); m.schedule(delayNs: 0, engineMs: 60); await sleepMs(10); m.schedule(delayNs: 0, engineMs: 20); await sleepMs(5); m.schedule(delayNs: 0, engineMs: 20)
    await m.drain()
    let st = m.stats
    check(st.overlaps == 0 && st.stalePublished == 0 && st.published == 1 && st.scheduled == 3 && st.passes == 2 && st.staleDropped == 1, "G: counters after a queued burst (\(st.summary))")
}
if bad > 0 { exit(1) }
print("ok")
'''
d = tempfile.mkdtemp(); f = pathlib.Path(d) / 'main.swift'; f.write_text(test)
swift = pathlib.Path(os.environ.get('SWIFT_BIN', '/tmp/swift-6.1.2-RELEASE-ubuntu22.04/usr/bin')) / 'swiftc'
r = subprocess.run([str(swift), str(f), '-o', d + '/t'], capture_output=True, text=True); assert r.returncode == 0, r.stderr
o = subprocess.run([d + '/t'], capture_output=True, text=True)
assert o.returncode == 0 and "ok" in o.stdout, (o.returncode, o.stdout, o.stderr[-300:])
# wiring (top-level await needs -parse-as-library off; swiftc main.swift supports it)
i0 = src.index('func scheduleFilter('); i1 = src.index('/// Largest-files and per-kind lists')
sf = src[i0:i1]
assert '150_000_000' not in sf, 'scheduleFilter must not hard-code the 150 ms wait'
assert 'let wasIdle = !filterPending' in sf and sf.index('let wasIdle = !filterPending') < sf.index('filterPending = true'), 'idle is read BEFORE pending is set'
assert 'let predecessor = filterTask' in sf and 'predecessor?.cancel()' in sf and sf.index('predecessor?.cancel()') < sf.index('filterTask = FilterCoalescer.start(after: predecessor'), 'predecessor captured, cancelled, then chained'
assert 'let debounceNs = immediate ? 0 : FilterDebounce.delayNs(lastFilterMs: lastActiveFilterMs, idle: wasIdle)' in sf, 'immediate runs still skip the wait'
assert 'stats.edit()' in sf and 'stats.passBegin()' in sf and 'stats.passEnd()' in sf and 'stats.publish(generation: generation, latest: self.filterGeneration)' in sf, 'counters wired'
assert sf.index('stats.passBegin()') < sf.index('tree.applyFilterChecked') < sf.index('stats.passEnd()'), 'passBegin/passEnd bracket the engine call'
assert sf.count('Perf.timingLog(') == 4 and all(k in sf for k in ('filter-key','filter-pass-start','filter-pass-end','filter-publish')), 'four stamps'
assert 'Task.detached' not in sf and 'Task.sleep' not in sf, 'scheduleFilter starts its pass only through the coalescer'
assert sf.count('lastActiveFilterMs = ms') == 1 and 'if active { self.lastActiveFilterMs = ms }' in sf, 'only an active pass updates the cost'
assert re.search(r'tree = t\n\s*lastActiveFilterMs = nil', src), 'the cost is forgotten when the tree is replaced'
print('PASS filter debounce + coalescer: real policy and FilterCoalescer.start compiled on Linux (bounds, idle=0, burst 3x cost, no overlapping passes, superseded edits never reach the engine, newest publishes); wiring checked by text (not a Mac result, not a latency measurement)')
