import Foundation
import AppKit
import ApplicationServices
import Darwin

// UNVERIFIED-COMPILE: prepared and self-reviewed statically on a machine with no
// Swift toolchain. The first approved Mac run compiles this file and lands any
// compile fixes as their own commit BEFORE any measurement.
//
// Milestone 3 interaction bench: measures typing, hover, and huge-folder
// expansion latency through external AX queries plus ordinary mouse/key input -
// the envelope ui-calibrate.swift declares (no attribute writes, no menus/Trash,
// disposable fixtures only). Runs ONLY inside an approved measurement run.
//
// WHAT THIS MEASURES: event-to-AX-visible latency - input event to an expected
// change being observable through AX. That is user-visible jank evidence, NOT
// proof the main thread was blocked. Synchronous AX reads can themselves stall,
// so every AX read is timed and each logged event carries its reads'
// count/total/max/failures; a read that returns after its observation deadline
// marks the event low_quality.
//
// KNOWN LIMITATIONS (labeled, not silently claimed away):
// - The typing "rowcount" metric is an UNCORRELATED AX observation: the outline
//   row-count change is not tied to the current keystroke's filter application,
//   so it is not a verified per-keystroke application latency.
// - Expansion mode's mechanism (matching a named row, its AXDisclosureTriangle,
//   and AXDisclosing state) is an UNVERIFIED CAPABILITY until the first approved
//   Mac run: for a profile-direct scan the profile root may not be a displayed
//   row, and whether the app exposes disclosure state through AX is unconfirmed.
// - The scanned path cannot be verified through AX. External preflight
//   (documented, not enforced): the operator scans the fixture PROFILE directory
//   directly (ROOT/typing-200k or ROOT/expansion-N per make_fixtures.py verify).
//
//   m3-interaction-bench typing    <pid> <out.jsonl> [keystrokes=200]
//   m3-interaction-bench hover     <pid> <out.jsonl> [sweeps=60]
//   m3-interaction-bench expansion <pid> <out.jsonl> <rowName> [reps=5]
//
// Exit codes: 0 clean, 2 usage/args, 3 AX trust, 4 landmarks/frontmost,
// 5 window geometry, 6 target row/triangle/disclosure state, 7 focus/field
// state, 8 output file, 9 log write failure, 10 run completed but INCONCLUSIVE
// (timeouts, failed ops, inconclusive observations, or AX read failures > 0).

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("usage: m3-interaction-bench <typing|hover|expansion> <pid> <out.jsonl> [args]"); exit(2)
}
let mode = args[1]
guard mode == "typing" || mode == "hover" || mode == "expansion" else { print("unknown mode \(mode)"); exit(2) }
guard let pid = Int32(args[2]), pid > 0 else { print("bad pid"); exit(2) }
let outPath = args[3]
var keystrokes = 200, sweeps = 60, reps = 5, rowName = ""
switch mode {
case "typing":
    guard args.count <= 5 else { print("unexpected extra arguments for typing"); exit(2) }
    if args.count == 5 { guard let v = Int(args[4]), v > 0 else { print("keystrokes must be > 0"); exit(2) }; keystrokes = v }
case "hover":
    guard args.count <= 5 else { print("unexpected extra arguments for hover"); exit(2) }
    if args.count == 5 { guard let v = Int(args[4]), v > 0 else { print("sweeps must be > 0"); exit(2) }; sweeps = v }
default:
    guard args.count >= 5, args.count <= 6, !args[4].isEmpty else { print("expansion needs <rowName> [reps]"); exit(2) }
    rowName = args[4]
    if args.count == 6 { guard let v = Int(args[5]), v > 0 else { print("reps must be > 0"); exit(2) }; reps = v }
}
// O_CREAT|O_EXCL|O_NOFOLLOW: an existing path or a dangling symlink at outPath
// fails the open outright - logs are never overwritten and never written
// through a planted link (no fileExists-then-create race).
let outFd = outPath.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644) }
guard outFd >= 0 else { print("REFUSED: cannot create \(outPath) exclusively (exists, or a symlink)"); exit(8) }
guard AXIsProcessTrusted() else { print("BLOCKED AX trust unavailable; not a measurement"); exit(3) }
let out = FileHandle(fileDescriptor: outFd, closeOnDealloc: true)

let app = AXUIElementCreateApplication(pid)
var axReadFailures = 0
func now() -> Double { ProcessInfo.processInfo.systemUptime }
struct ReadStats {
    var count = 0, failures = 0
    var totalMs = 0.0, maxMs = 0.0
    mutating func add(_ ms: Double, failed: Bool) {
        count += 1; totalMs += ms; maxMs = max(maxMs, ms); if failed { failures += 1 }
    }
    var dict: [String: Any] { ["read_count": count, "read_failures": failures,
                               "read_ms_total": totalMs, "read_ms_max": maxMs] }
}
// Every AX read is timed. failed means a real API error (attribute-absent is
// normal and does not count).
func readTimed(_ element: AXUIElement, _ name: String) -> (CFTypeRef?, Double, Bool) {
    let start = now()
    var result: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, name as CFString, &result)
    let ms = (now() - start) * 1000
    let failed = err != .success && err != .attributeUnsupported && err != .noValue
    if failed { axReadFailures += 1 }
    return (err == .success ? result : nil, ms, failed)
}
func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? { readTimed(element, name).0 }
func string(_ element: AXUIElement, _ name: String) -> String { read(element, name) as? String ?? "" }
func descendants() -> [AXUIElement] {
    var queue = [app], seen = [AXUIElement](), i = 0
    while i < queue.count && seen.count < 256 {
        let element = queue[i]; i += 1
        if seen.contains(where: { CFEqual($0, element) }) { continue }
        seen.append(element)
        if string(element, "AXRole") == "AXTable" { continue }
        if let children = read(element, "AXChildren") as? [AXUIElement] { queue += children }
        if CFEqual(element, app), let windows = read(element, "AXWindows") as? [AXUIElement] { queue += windows }
    }
    return seen
}
func one(_ role: String, _ description: String) -> AXUIElement? {
    let matches = descendants().filter { string($0, "AXRole") == role && string($0, "AXDescription") == description }
    return matches.count == 1 ? matches[0] : nil
}
// Count-only row read: never materializes the AXRows array.
func rowCountTimed(_ table: AXUIElement) -> (Int?, Double, Bool) {
    let start = now()
    var count: CFIndex = 0
    let err = AXUIElementGetAttributeValueCount(table, "AXRows" as CFString, &count)
    let ms = (now() - start) * 1000
    let failed = err != .success && err != .attributeUnsupported && err != .noValue
    if failed { axReadFailures += 1 }
    return (err == .success ? Int(count) : nil, ms, failed)
}
// Elapsed is always measured from the caller's t0, taken BEFORE the input event.
// A condition whose final read returns after the deadline still reports its
// (late) elapsed; callers mark that event low_quality.
func until(_ t0: Double, _ timeout: Double, interval: UInt32 = 10_000, _ condition: () -> Bool) -> Double? {
    let deadline = t0 + timeout
    repeat { if condition() { return (now() - t0) * 1000 } ; usleep(interval) } while now() < deadline
    return nil
}
func frame(_ element: AXUIElement) -> CGRect? {
    guard let pv = read(element, "AXPosition"), let sv = read(element, "AXSize"),
          CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
    return CGRect(origin: p, size: s)
}
func click(_ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(40_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}
func type(_ character: Character) {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
    var utf = Array(String(character).utf16)
    utf.withUnsafeBufferPointer { buf in
        down?.keyboardSetUnicodeString(stringLength: utf.count, unicodeString: buf.baseAddress)
        up?.keyboardSetUnicodeString(stringLength: utf.count, unicodeString: buf.baseAddress)
    }
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}
func key(_ virtualKey: UInt16) {
    CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: false)?.post(tap: .cghidEventTap)
}
let kDelete: UInt16 = 51
func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return -1 }
    let rank = min(sorted.count - 1, max(0, Int((p / 100 * Double(sorted.count - 1)).rounded(.up))))
    return sorted[rank]
}
func emit(_ object: [String: Any]) {
    do {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0a)
        try out.write(contentsOf: data) // throwing write: log failures are fatal (exit 9)
    } catch {
        print("FATAL: log write failed: \(error)"); exit(9)
    }
}
func frontmost() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
func frontmostAndFocused(_ field: AXUIElement) -> Bool {
    frontmost() && (read(field, "AXFocused") as? Bool) == true
}
func summary(_ object: [String: Any], inconclusive: Int) -> Never {
    var withCommon = object
    withCommon["ax_read_failures"] = axReadFailures
    withCommon["limitation"] = "event-to-AX-visible latency only; not proof of main-thread block"
    let clean = inconclusive == 0 && axReadFailures == 0
    withCommon["status"] = clean ? "complete" : "inconclusive"
    emit(withCommon)
    guard let data = try? JSONSerialization.data(withJSONObject: withCommon) else { exit(9) }
    print(String(data: data, encoding: .utf8) ?? "")
    exit(clean ? 0 : 10)
}

// Shared landmarks (same names ui-calibrate.swift pins), before any input.
guard let running = NSRunningApplication(processIdentifier: pid), running.activate(),
      until(now(), 5, interval: 250_000, { frontmost() }) != nil,
      until(now(), 30, interval: 250_000, { one("AXTable", "Folder outline") != nil && one("AXTextField", "Filter by name") != nil }) != nil,
      let table = one("AXTable", "Folder outline"), let field = one("AXTextField", "Filter by name"),
      let fieldFrame = frame(field) else { exit(4) }
let windows = read(app, "AXWindows") as? [AXUIElement] ?? []
guard windows.count == 1, let winFrame = frame(windows[0]), winFrame.width > 0 else { exit(5) }
emit(["header": "m3-interaction-bench", "mode": mode, "pid": pid,
      "limitation": "event-to-AX-visible latency only; not proof of main-thread block",
      "rowcount_note": "typing rowcount is an uncorrelated AX observation, not verified per-keystroke application latency",
      "expansion_note": "named-row/disclosure mechanism is an unverified capability until the first approved Mac run",
      "preflight": "operator scanned the fixture profile dir directly; AX cannot verify the scanned path"])

if mode == "typing" {
    // Preflight: the field must read SUCCESSFULLY as empty - a failed read never
    // masquerades as an empty string.
    let (v0, _, v0Failed) = readTimed(field, "AXValue")
    guard !v0Failed, let s0 = v0 as? String, s0.isEmpty else { print("filter field not verifiably empty at start"); exit(7) }
    guard frontmost() else { exit(4) }
    click(CGPoint(x: fieldFrame.midX, y: fieldFrame.midY))
    guard until(now(), 2, { frontmostAndFocused(field) }) != nil else { print("filter field did not take focus"); exit(7) }
    // Settle-then-measure: a row-count baseline is only trusted once the count
    // STABILIZES (two consecutive equal successful reads; a failed read resets
    // the streak). The previous run read the baseline ~30ms after the prior
    // keystroke, before that key's filter had settled, making per-key
    // correlation impossible (187/200 keys inconclusive).
    func settleRowCount(_ window: Double, _ stats: inout ReadStats) -> Int? {
        let deadline = now() + window
        var last: Int? = nil
        while now() < deadline {
            let (c, ms, failed) = rowCountTimed(table)
            stats.add(ms, failed: failed)
            guard !failed, let c else { last = nil; usleep(20_000); continue }
            if c == last { return c }
            last = c
            usleep(20_000)
        }
        return nil
    }
    var preStats = ReadStats()
    guard let settledStart = settleRowCount(5.0, &preStats) else { print("row count did not settle before typing; aborting"); exit(7) }
    var baseline = settledStart
    let stream = Array("invoice backup photo archive render cache export draft ")
    var fieldMs = [Double](), rowcountMs = [Double]()
    var inconclusive = 0, degradedEvents = 0
    var typed = ""
    for i in 0..<keystrokes {
        guard frontmostAndFocused(field) else { print("focus lost before key \(i); aborting"); exit(7) }
        let ch = stream[i % stream.count]
        let expected = typed + String(ch)
        var stats = ReadStats()
        let rowsBefore: Int? = baseline // settled after the previous key, never a 30ms-stale read
        let t0 = now()
        type(ch)
        // Field: exact full-string equality on SUCCESSFUL reads only.
        let fWindow = 2.0
        let f = until(t0, fWindow, {
            let (v, ms, failed) = readTimed(field, "AXValue")
            stats.add(ms, failed: failed)
            guard !failed, let s = v as? String else { return false }
            return s == expected
        })
        // A field-update timeout breaks the per-key premise: stop, do not keep
        // typing blind and do not fire deletes into an unknown field state.
        guard let f else {
            var abortEvent: [String: Any] = ["event": "abort", "reason": "field update timeout", "i": i, "expected_field": expected]
            for (k, v) in stats.dict { abortEvent[k] = v }
            emit(abortEvent)
            print("field update timeout at key \(i); aborting"); exit(7)
        }
        // Row-count observation against the SETTLED baseline: t0(type) until
        // the count moves shows this key's filter applied; it is not a
        // render-completion claim.
        let rWindow = 2.0
        let r = until(t0, rWindow, {
            let (c, ms, failed) = rowCountTimed(table)
            stats.add(ms, failed: failed)
            guard !failed, let c, let rowsBefore else { return false }
            return c != rowsBefore
        })
        // Quality accounting: a late-returning read or any failed AX read makes
        // the event degraded - excluded from percentile samples and counted,
        // so a degraded run can never summarize as clean.
        let fieldLow = f > fWindow * 1000
        let rowcountLow = (r ?? .infinity) > rWindow * 1000
        let degraded = fieldLow || rowcountLow || stats.failures > 0
        var event: [String: Any] = ["event": "key", "i": i, "char": String(ch), "expected_field": expected,
            "field_ms": f, "field_low_quality": fieldLow,
            "rowcount_ms": r ?? -1, "rowcount_verdict": r != nil ? "changed" : "inconclusive",
            "rowcount_low_quality": rowcountLow,
            "rowcount_baseline": "settled", "rows_before": rowsBefore ?? -1,
            "degraded": degraded]
        for (k, v) in stats.dict { event[k] = v }
        emit(event)
        if !degraded {
            fieldMs.append(f)
            if let r { rowcountMs.append(r) } else { inconclusive += 1 }
        } else { degradedEvents += 1; if r == nil { inconclusive += 1 } }
        // Settle before the next key: without a fresh verified baseline the
        // serial per-key premise is broken, so a settle failure aborts the run
        // rather than degrading into uncorrelated measurements.
        guard let settled = settleRowCount(5.0, &stats) else {
            print("row count did not settle after key \(i); next baseline unverifiable; aborting"); exit(7)
        }
        baseline = settled
        usleep(30_000) // serial-latency mode: one key measured at a time; no rate claim
        typed.append(ch)
        if typed.count >= 24 { // keep the filter short; clear with real delete-key events
            for _ in 0..<typed.count {
                guard frontmostAndFocused(field) else { print("focus lost mid-delete; aborting"); exit(7) }
                key(kDelete); usleep(5_000)
            }
            typed = ""
            // Run 37848565420 evidence: the delete burst is processed by the app
            // asynchronously (24 deletes at 5ms on a 200k-row fixture, each
            // re-applying the filter - filterPending in the app is async), so a
            // single immediate AXValue read raced the app's own event queue;
            // run 37834771695 passed the identical step on timing luck. The
            // REQUIREMENT is unchanged: the field must read verifiably empty
            // before typing resumes, otherwise abort. The verification now
            // polls with the same bounded-until pattern as the focus and
            // field-update checks above instead of reading exactly once.
            let cleared = until(now(), 5.0, {
                let (vc, _, vcFailed) = readTimed(field, "AXValue")
                guard !vcFailed, let sc = vc as? String else { return false }
                return sc.isEmpty
            })
            guard cleared != nil else {
                print("filter field failed to clear verifiably; aborting"); exit(7)
            }
            guard let settledCleared = settleRowCount(5.0, &stats) else {
                print("row count did not settle after clearing; next baseline unverifiable; aborting"); exit(7)
            }
            baseline = settledCleared
        }
    }
    fieldMs.sort(); rowcountMs.sort()
    summary(["kind": "m3-typing", "pid": pid, "n": keystrokes, "mode_note": "serial per-key latency; not a burst/typist-rate measurement",
        "field_p50": percentile(fieldMs, 50), "field_p95": percentile(fieldMs, 95),
        "rowcount_p50": percentile(rowcountMs, 50), "rowcount_p95": percentile(rowcountMs, 95),
        "rowcount_note": "t0(type) until the settled row count moves; shows the filter applied, not render completion",
        "rowcount_inconclusive": inconclusive, "degraded_events": degradedEvents], inconclusive: inconclusive + degradedEvents)
}

if mode == "hover" {
    // AX HIT-TEST request latency only: how long until the element under the new
    // pointer position resolves. No hover-render or highlight causality is claimed.
    var lagMs = [Double](), queryMs = [Double](), over100 = 0, inconclusive = 0, degradedEvents = 0
    let cols = 6, rows = 4
    for s in 0..<sweeps {
        guard frontmost() else { print("frontmost lost before hover \(s); aborting"); exit(4) }
        let gx = s % cols, gy = (s / cols) % rows
        let x = winFrame.minX + winFrame.width * (0.1 + 0.8 * Double(gx) / Double(cols - 1))
        let y = winFrame.minY + winFrame.height * (0.15 + 0.75 * Double(gy) / Double(rows - 1))
        var stats = ReadStats()
        let t0 = now() // anchor BEFORE the posted move
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
        var role = "none"
        let window = 1.0
        let lag = until(t0, window, {
            var hit: AXUIElement?
            let q0 = now()
            let err = AXUIElementCopyElementAtPosition(app, Float(x), Float(y), &hit)
            let qMs = (now() - q0) * 1000
            let failed = err != .success && err != .noValue && err != .attributeUnsupported
            stats.add(qMs, failed: failed)
            guard err == .success, let hit else { return false }
            let (rv, rms, rfailed) = readTimed(hit, "AXRole")
            stats.add(rms, failed: rfailed)
            role = rv as? String ?? "unknown"
            return true
        })
        // Quality accounting includes per-event hit-test failures: any failed
        // AX call inside the event degrades it.
        let lagLow = (lag ?? .infinity) > window * 1000
        let degraded = lagLow || stats.failures > 0
        var event: [String: Any] = ["event": "hover", "sweep": s, "x": x, "y": y, "element_role": role,
            "hittest_ms": lag ?? -1, "hittest_low_quality": lagLow, "degraded": degraded]
        for (k, v) in stats.dict { event[k] = v }
        emit(event)
        if let lag, !degraded {
            lagMs.append(lag); if lag > 100 { over100 += 1 }
            if stats.maxMs > 0 { queryMs.append(stats.maxMs) }
        } else if lag == nil { inconclusive += 1 } else { degradedEvents += 1 }
        usleep(50_000)
    }
    lagMs.sort(); queryMs.sort()
    summary(["kind": "m3-hover-ax-hittest", "pid": pid, "sweeps": sweeps,
        "note": "AX hit-test request latency only; no hover-render or highlight causality",
        "hittest_p50": percentile(lagMs, 50), "hittest_p95": percentile(lagMs, 95),
        "ax_query_max_p50": percentile(queryMs, 50), "ax_query_max_p95": percentile(queryMs, 95),
        "over_100ms": over100, "timeouts": inconclusive, "degraded_events": degradedEvents], inconclusive: inconclusive + degradedEvents)
}

if mode == "expansion" {
    // Bounded preflight: poll the visible-row COUNT only - at 10k/100k rows the
    // flat AXRows array materialization is the expensive step (AXRowCount
    // polling is proven at 100001 rows), so the old 256-row cap on AXRows made
    // the mode refuse exactly the fixtures it exists to measure.
    // Run 37848565420 evidence corrected the follow-on assumption too: the
    // expansion fixtures START FULLY EXPANDED, so the table's top-level
    // AXChildren holds every visible row (observed 10002 and 100002) - one
    // bulk AXChildren read materializes the entire outline and the 256-row
    // guard refused both fixtures (exit 6) without measuring anything. The
    // named target row is now located by CHUNKED top-level reads
    // (AXUIElementCopyAttributeValues with a CFRange, 256 rows per chunk)
    // over a bounded window of at most maxChunks chunks. Exactly one match
    // within that window is required: zero matches, multiple matches, a
    // short chunk (identity churn mid-scan), or a chunk read error all
    // abort - the bench never rescans blind and never clicks an unverified
    // row. Uniqueness is verified over the bounded window, not the whole
    // outline; fixture evidence places the named root row at index 0. The
    // validated row handle is REUSED for every rep (no per-rep scans). If
    // the app's identity churn invalidates the handle, its reads fail and
    // the run aborts.
    let (initialCount, _, initialFailed) = rowCountTimed(table)
    guard !initialFailed, let initialCount else { print("row count unreadable at preflight"); exit(6) }
    var topChildCount: CFIndex = 0
    let countErr = AXUIElementGetAttributeValueCount(table, kAXChildrenAttribute as CFString, &topChildCount)
    guard countErr == .success else { axReadFailures += 1; print("top-level children count unreadable at preflight"); exit(6) }
    let totalChildren = Int(topChildCount)
    let chunkSize = 256, maxChunks = 8 // bounded window: at most 2048 rows scanned
    let windowRows = min(totalChildren, chunkSize * maxChunks)
    var matches = [AXUIElement](), scanned = 0
    while scanned < windowRows {
        let want = min(chunkSize, windowRows - scanned)
        var chunkRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValues(table, kAXChildrenAttribute as CFString,
                                                 CFRange(location: scanned, length: want), &chunkRef)
        guard err == .success, let chunkRows = chunkRef as? [AXUIElement] else {
            if err != .success && err != .noValue { axReadFailures += 1 }
            print("chunked top-level children read failed at offset \(scanned) of \(totalChildren) (AXError \(err.rawValue)); not scanning blind"); exit(6)
        }
        guard chunkRows.count == want else { print("short chunked read at offset \(scanned): got \(chunkRows.count) of \(want) (identity churn mid-scan); aborting"); exit(6) }
        for candidate in chunkRows {
            if string(candidate, "AXDescription") == rowName { matches.append(candidate); continue }
            let cells = read(candidate, "AXChildren") as? [AXUIElement] ?? []
            if cells.contains(where: { string($0, "AXDescription") == rowName || string($0, "AXValue") == rowName }) { matches.append(candidate) }
        }
        scanned += chunkRows.count
    }
    guard matches.count == 1, let row = matches.first else { print("target row not unique or absent within bounded scan (\(matches.count) matches in \(scanned) scanned rows of \(totalChildren) top-level children, visible count \(initialCount)): \(rowName)"); exit(6) }
    let cells0 = read(row, "AXChildren") as? [AXUIElement] ?? []
    guard let tri = (cells0.first { string($0, "AXRole") == "AXDisclosureTriangle" } ?? (string(row, "AXRole") == "AXDisclosureTriangle" ? row : nil)),
          frame(tri) != nil else { print("target row has no usable disclosure triangle: \(rowName)"); exit(6) }
    var latMs = [Double](), jank = 0, inconclusive = 0, degradedEvents = 0
    for rep in 0..<reps {
        // Disclosure STATE must be a valid Bool before any input - a missing or
        // failed read aborts the run rather than defaulting to false.
        let (dv, _, dFailed) = readTimed(row, "AXDisclosing")
        guard !dFailed, let disclosing = dv as? Bool else {
            print("AXDisclosing unreadable at rep \(rep) (unverified capability or stale handle); aborting"); exit(6)
        }
        let expectExpand = !disclosing
        guard let triFrame = frame(tri) else { print("triangle frame lost at rep \(rep)"); exit(6) }
        guard frontmost() else { print("frontmost lost before click at rep \(rep)"); exit(4) }
        var stats = ReadStats()
        let (rowsBefore, beforeMs, beforeFailed) = rowCountTimed(table)
        stats.add(beforeMs, failed: beforeFailed)
        guard let rowsBefore else { print("row count unreadable at rep \(rep)"); inconclusive += 1; continue }
        let t0 = now()
        click(CGPoint(x: triFrame.midX, y: triFrame.midY))
        let window = 30.0 // 1m children can legitimately take seconds
        let lat = until(t0, window, {
            let (c, ms, failed) = rowCountTimed(table)
            stats.add(ms, failed: failed)
            guard !failed, let c else { return false }
            return expectExpand ? c > rowsBefore : c < rowsBefore
        })
        let (rowsAfter, afterMs, afterFailed) = rowCountTimed(table)
        stats.add(afterMs, failed: afterFailed)
        let (dva, dma, dfa) = readTimed(row, "AXDisclosing")
        stats.add(dma, failed: dfa)
        let flippedState = (dva as? Bool).map { $0 == expectExpand } ?? false
        let stateFlipped = !dfa && flippedState
        let countMoved = rowsAfter.map { expectExpand ? $0 > rowsBefore : $0 < rowsBefore } ?? false
        let latLow = (lat ?? .infinity) > window * 1000
        let degraded = latLow || stats.failures > 0
        let ok = lat != nil && countMoved && stateFlipped && !degraded
        if !ok { inconclusive += 1 }
        if degraded { degradedEvents += 1 }
        if ok, expectExpand, let lat { latMs.append(lat); if lat > 100 { jank += 1 } }
        var event: [String: Any] = ["event": expectExpand ? "expand" : "collapse", "rep": rep,
            "rows_before": rowsBefore, "rows_after": rowsAfter ?? -1,
            "latency_ms": lat ?? -1, "latency_low_quality": latLow,
            "ok": ok, "state_flipped": stateFlipped, "degraded": degraded,
            "jank_over_100ms": ok && expectExpand && (lat ?? 0) > 100]
        for (k, v) in stats.dict { event[k] = v }
        emit(event)
        usleep(500_000)
    }
    latMs.sort()
    summary(["kind": "m3-expansion", "pid": pid, "row": rowName, "reps": reps,
        "capability_note": "named-row/disclosure mechanism unverified until the first approved Mac run",
        "expand_p50": percentile(latMs, 50), "expand_p95": percentile(latMs, 95),
        "jank_over_100ms": jank, "expansions_measured": latMs.count,
        "inconclusive_or_failed": inconclusive, "degraded_events": degradedEvents], inconclusive: inconclusive)
}
