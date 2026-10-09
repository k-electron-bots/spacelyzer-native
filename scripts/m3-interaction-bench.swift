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
// - The typing "footer" metric is event-to-AX-visible latency: t0(key) until
//   the app's own footer summary container republishes the filter result. The
//   observed element is the combined summary container whose AXLabel/AXHelp is
//   ContentView's fullDetails string (rootPath, totals, and - while a filter
//   is active - "Filter: <bytes>, <N files>, <X.X> milliseconds"); the
//   "Scanned folder:" path Text is a separate element that never changes and
//   is NOT the signal. The row-count signal was dropped after run 37870201922
//   proved it blind (count never moved across 200 keys under filter "i"). The
//   app-reported filter ms parsed from the footer is corroboration only, not
//   independently verified.
// - Expansion mode's mechanism (matching a named row, its chevron button's
//   AXLabel "Expand <name>"/"Collapse <name>" as state and click target, with
//   the chevron image's AXDescription "Expand"/"Collapse" as fallback) is an
//   UNVERIFIED CAPABILITY until the first successful expansion measurement:
//   run 37864247016 confirmed the profile root is NOT a displayed row under a
//   direct scan, and run 37870201922 confirmed the row has no
//   AXDisclosureTriangle/AXDisclosing (custom chevron per OutlineView.swift).
// - The scanned path cannot be verified through AX. External preflight
//   (documented, not enforced): typing scans the fixture PROFILE directory
//   directly (ROOT/typing-200k); expansion scans the profile's WRAPPER
//   directory (exactly one fixture inside) so the huge folder is a real
//   outline row - see docs/m3-measurement-protocol.md.
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
      "typing_note": "typing measures t0(key) until the app's own footer republishes the filter result; event-to-AX-visible latency, not render completion",
      "expansion_note": "named-row/disclosure mechanism is an unverified capability until the first approved Mac run",
      "preflight": "typing scanned the profile dir directly; expansion scanned its one-fixture wrapper; AX cannot verify the scanned path"])

if mode == "typing" {
    // Preflight: the field must read SUCCESSFULLY as empty - a failed read never
    // masquerades as an empty string.
    let (v0, _, v0Failed) = readTimed(field, "AXValue")
    guard !v0Failed, let s0 = v0 as? String, s0.isEmpty else { print("filter field not verifiably empty at start"); exit(7) }
    guard frontmost() else { exit(4) }
    click(CGPoint(x: fieldFrame.midX, y: fieldFrame.midY))
    guard until(now(), 2, { frontmostAndFocused(field) }) != nil else { print("filter field did not take focus"); exit(7) }
    // Observable: the app's own footer summary container, not the row count.
    // Run 37870201922 evidence: the row count NEVER moved across all 200
    // toggle keys (6s window, 0 ax_read_failures, every settle succeeded) -
    // the filtered outline keeps the same row count under filter "i", so the
    // count signal is blind to the stall it exists to measure. The app
    // publishes every filter result in its footer (ContentView fullDetails:
    // "Filter: <bytes>, <N files>, <X.X> milliseconds"; proven AX-visible by
    // the footer gate in runs 37864247016 and 37870201922), so the summary
    // container's text changes on every applied filter change - including a
    // clear, which removes the line. The element is the combined summary
    // container (.accessibilityElement(children: .combine) with AXLabel and
    // AXHelp both set to fullDetails), NOT the separate "Scanned folder:"
    // path Text, which never changes.
    // Settle-then-measure: a footer-text baseline is only trusted once it
    // STABILIZES (two consecutive equal successful reads; a failed read
    // resets the streak).
    // "Filter: 1.2 MB, 25,000 files, 34.5 milliseconds" -> 34.5; the app's
    // OWN reported filter time, corroboration only - not independently
    // verified, never mixed into the measured latencies.
    func appFilterMs(_ footerText: String) -> Double? {
        guard let range = footerText.range(of: " milliseconds") else { return nil }
        let before = footerText[..<range.lowerBound]
        guard let lastSpace = before.lastIndex(of: " ") else { return nil }
        return Double(before[before.index(after: lastSpace)...])
    }
    // Discovery: the summary container is the only bounded-walker element
    // whose AXLabel/AXHelp/AXValue contains " items" (fullDetails: "<rootPath>
    // <size> in <N> items..."). The "Scanned folder:" path Text is a sibling
    // that never carries " items"; outline rows (which do) sit under the
    // AXTable the walker skips. Not unique -> abort, never guess.
    let footers = descendants().filter { el in
        for attr in ["AXLabel", "AXHelp", "AXValue"] where string(el, attr).contains(" items") { return true }
        return false
    }
    guard footers.count == 1, let footer = footers.first else { print("footer summary container not uniquely discoverable (\(footers.count) matches); aborting"); exit(7) }
    // One footer text read: AXLabel (set to fullDetails) first, AXHelp (also
    // fullDetails) and AXValue as fallbacks; every attempted read is timed
    // and accounted in stats.
    func footerRead(_ stats: inout ReadStats) -> String? {
        for attr in ["AXLabel", "AXHelp", "AXValue"] {
            let (v, ms, failed) = readTimed(footer, attr)
            stats.add(ms, failed: failed)
            if !failed, let s = v as? String, !s.isEmpty { return s }
        }
        return nil
    }
    func settleFooter(_ window: Double, _ stats: inout ReadStats) -> String? {
        let deadline = now() + window
        var last: String? = nil
        while now() < deadline {
            guard let s = footerRead(&stats) else { last = nil; usleep(20_000); continue }
            if s == last { return s }
            last = s
            usleep(20_000)
        }
        return nil
    }
    var preStats = ReadStats()
    guard let settledStart = settleFooter(5.0, &preStats) else { print("footer text did not settle before typing; aborting"); exit(7) }
    var baseline = settledStart
    var fieldMs = [Double](), footerMs = [Double](), appMs = [Double]()
    var inconclusive = 0, degradedEvents = 0
    var typed = ""
    for i in 0..<keystrokes {
        guard frontmostAndFocused(field) else { print("focus lost before key \(i); aborting"); exit(7) }
        // Toggle stream: every key MUST change the applied filter, or the
        // footer-republish signal cannot fire. Run 37864247016 evidence: the
        // accumulating multi-word stream left 187/200 keys with no filter
        // change - same-prefix refinement ("i"->"in"->... all match the
        // same set) and the 0-match plateau after the first space. This
        // stream alternates "" <-> "i": filter.rs contains_ci substring
        // matching over the fixture word inventory (make_fixtures.py:
        // invoice_* and archive_* contain "i"; backup/photo/render/cache/
        // export/draft do not) makes every keystroke change the published
        // filter result.
        let expanding = typed.isEmpty
        let expected = expanding ? "i" : ""
        var stats = ReadStats()
        let footerBefore = baseline // settled after the previous key, never a stale read
        let t0 = now()
        if expanding { type("i") } else { key(kDelete) }
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
        // Footer observation against the SETTLED text: t0(type) until the
        // footer republishes shows this key's filter applied; it is not a
        // render-completion claim.
        let ftrWindow = 6.0
        var observed = ""
        let r = until(t0, ftrWindow, {
            guard let s = footerRead(&stats) else { return false }
            if s != footerBefore { observed = s; return true }
            return false
        })
        // Quality accounting: a late-returning read or any failed AX read makes
        // the event degraded - excluded from percentile samples and counted,
        // so a degraded run can never summarize as clean.
        let fieldLow = f > fWindow * 1000
        let footerLow = (r ?? .infinity) > ftrWindow * 1000
        let degraded = fieldLow || footerLow || stats.failures > 0
        var event: [String: Any] = ["event": "key", "i": i, "char": expanding ? "i" : "delete", "expected_field": expected,
            "field_ms": f, "field_low_quality": fieldLow,
            "footer_ms": r ?? -1, "footer_verdict": r != nil ? "republished" : "inconclusive",
            "footer_low_quality": footerLow,
            "footer_baseline": "settled",
            "app_filter_ms": appFilterMs(observed) ?? -1,
            "degraded": degraded]
        for (k, v) in stats.dict { event[k] = v }
        emit(event)
        if !degraded {
            fieldMs.append(f)
            if let r { footerMs.append(r); if let a = appFilterMs(observed) { appMs.append(a) } } else { inconclusive += 1 }
        } else { degradedEvents += 1; if r == nil { inconclusive += 1 } }
        // Settle before the next key: without a fresh verified baseline the
        // serial per-key premise is broken, so a settle failure aborts the run
        // rather than degrading into uncorrelated measurements.
        guard let settled = settleFooter(5.0, &stats) else {
            print("footer text did not settle after key \(i); next baseline unverifiable; aborting"); exit(7)
        }
        if settled != baseline { print("settled footer changed after key \(i)") }
        baseline = settled
        usleep(30_000) // serial-latency mode: one key measured at a time; no rate claim
        typed = expected
    }
    fieldMs.sort(); footerMs.sort(); appMs.sort()
    summary(["kind": "m3-typing", "pid": pid, "n": keystrokes, "mode_note": "serial per-key latency; not a burst/typist-rate measurement",
        "field_p50": percentile(fieldMs, 50), "field_p95": percentile(fieldMs, 95),
        "footer_p50": percentile(footerMs, 50), "footer_p95": percentile(footerMs, 95),
        "footer_note": "t0(type) until the app's footer republishes the filter result; shows the filter applied, not render completion",
        "app_filter_p50": percentile(appMs, 50), "app_filter_p95": percentile(appMs, 95),
        "app_filter_note": "the app's OWN footer-reported filter time; corroboration only, not independently verified",
        "footer_inconclusive": inconclusive, "degraded_events": degradedEvents], inconclusive: inconclusive + degradedEvents)
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
    // Run 37864247016 evidence: the named row NEVER existed under a direct
    // scan - the app's outline (engine visible_rows) lists the scanned
    // root's CHILDREN at depth 0, the root itself is never a row, so both
    // fixtures exited 6 with "0 matches in 2048 scanned rows". The workflow
    // now scans the fixture's WRAPPER directory (m3fix-exp*, which contains
    // exactly one fixture), so the huge folder IS a top-level row with a
    // disclosure triangle and starts COLLAPSED: expanding it materializes
    // its 10k/100k children - the stall this mode exists to measure. The
    // wrapper adds exactly one scan node. Top-level AXChildren is small by
    // design again; the bounded chunked lookup below stays as the mechanism
    // (AXUIElementCopyAttributeValues chunked reads, CFIndex index +
    // maxValues, 256 rows per chunk over at most maxChunks chunks). Exactly
    // one match within that window is required: zero matches, multiple
    // matches, a short chunk (identity churn mid-scan), or a chunk read
    // error all abort - the bench never rescans blind and never clicks an
    // unverified row. The validated row handle is REUSED for every rep (no
    // per-rep scans). If the app's identity churn invalidates the handle,
    // its reads fail and the run aborts.
    let (initialCount, _, initialFailed) = rowCountTimed(table)
    guard !initialFailed, let initialCount else { print("row count unreadable at preflight"); exit(6) }
    var topChildCount: CFIndex = 0
    let countErr = AXUIElementGetAttributeValueCount(table, kAXChildrenAttribute as CFString, &topChildCount)
    guard countErr == AXError.success else { axReadFailures += 1; print("top-level children count unreadable at preflight"); exit(6) }
    let totalChildren = Int(topChildCount)
    // Chunked reads use this SDK's 5-argument AXUIElementCopyAttributeValues
    // (CFIndex index, CFIndex maxValues - the compiler in run 37862559550 printed
    // the signature; the CFRange form does not exist here, and run 37861420537's
    // "cannot infer contextual base" was the same call misresolved). AXError
    // bases stay explicit for consistency with the rest of the file.
    let chunkSize = 256, maxChunks = 8 // bounded window: at most 2048 rows scanned
    let windowRows = min(totalChildren, chunkSize * maxChunks)
    var matches = [AXUIElement](), scanned = 0
    while scanned < windowRows {
        let want = min(chunkSize, windowRows - scanned)
        var chunkRef: CFArray?
        let err = AXUIElementCopyAttributeValues(table, kAXChildrenAttribute as CFString,
                                                 scanned, want, &chunkRef)
        guard err == AXError.success, let chunkRows = chunkRef as? [AXUIElement] else {
            if err != AXError.success && err != AXError.noValue { axReadFailures += 1 }
            print("chunked top-level children read failed at offset \(scanned) of \(totalChildren) (AXError \(err.rawValue)); not scanning blind"); exit(6)
        }
        guard chunkRows.count == want else { print("short chunked read at offset \(scanned): got \(chunkRows.count) of \(want) (identity churn mid-scan); aborting"); exit(6) }
        // Run 37867383313 evidence: under the wrapper scan the target row
        // EXISTS (2 top-level children) but exact == on AXDescription/AXValue
        // found 0 matches - the row's accessible name form is unknown. Match
        // on CONTAINS across the name-bearing attributes on the row and its
        // direct cells; the fixture name is unique in the tree by design, so
        // a substring match stays exact in effect. On failure, dump the
        // scanned rows' attributes so the log discloses the real form.
        func exposedText(_ el: AXUIElement) -> [String] {
            ["AXDescription", "AXTitle", "AXValue", "AXLabel"].map { string(el, $0) }.filter { !$0.isEmpty }
        }
        func named(_ el: AXUIElement) -> Bool {
            if exposedText(el).contains(where: { $0.contains(rowName) }) { return true }
            let cells = read(el, "AXChildren") as? [AXUIElement] ?? []
            return cells.contains(where: { exposedText($0).contains(where: { $0.contains(rowName) }) })
        }
        for candidate in chunkRows {
            if named(candidate) { matches.append(candidate) }
        }
        scanned += chunkRows.count
    }
    if matches.count != 1 {
        let dump = min(scanned, 8)
        var diag = ""
        var diagRef: CFArray?
        let diagErr = AXUIElementCopyAttributeValues(table, kAXChildrenAttribute as CFString, 0, dump, &diagRef)
        if diagErr == AXError.success, let diagRows = diagRef as? [AXUIElement] {
            for (i, r) in diagRows.enumerated() {
                let role = string(r, "AXRole")
                let texts = ["AXDescription", "AXTitle", "AXValue", "AXLabel"].map { "\($0)=\(string(r, $0))" }.joined(separator: " ")
                let cells = read(r, "AXChildren") as? [AXUIElement] ?? []
                let cellTexts = cells.prefix(4).map { c in "[" + ["AXDescription", "AXTitle", "AXValue", "AXLabel"].map { "\($0)=\(string(c, $0))" }.joined(separator: " ") + "]" }.joined(separator: " ")
                diag += " row[\(i)] role=\(role) \(texts) cells=\(cellTexts);"
            }
        } else { diag = " diagnostic re-read failed (AXError \(diagErr.rawValue))" }
        print("target row not unique or absent within bounded scan (\(matches.count) matches in \(scanned) scanned rows of \(totalChildren) top-level children, visible count \(initialCount)): \(rowName);\(diag)"); exit(6)
    }
    let row = matches[0]
    // Run 37870201922 evidence: the row matches by name but "has no usable
    // disclosure triangle" - the app renders its own chevron as an NSButton
    // whose AXLabel is "Expand <name>"/"Collapse <name>" (OutlineView.swift:
    // cell.chevron.setAccessibilityLabel), never an AXDisclosureTriangle, and
    // the row exposes no AXDisclosing. The chevron button's label IS the
    // expansion state; its frame is the click target. Fallback: the chevron's
    // NSImage carries accessibilityDescription "Expand"/"Collapse" (no name),
    // matched exactly on AXDescription. Discovery is bounded: the row's
    // direct cells and their direct children only; state is re-scanned every
    // call so each rep reads fresh state.
    // nil when the element carries no chevron signal; false = collapsed
    // ("Expand ..."), true = expanded ("Collapse ...").
    func chevronStateText(_ el: AXUIElement) -> Bool? {
        for attr in ["AXLabel", "AXTitle"] {
            let t = string(el, attr)
            if t.hasPrefix("Expand ") { return false }
            if t.hasPrefix("Collapse ") { return true }
        }
        let d = string(el, "AXDescription")
        if d == "Expand" { return false }
        if d == "Collapse" { return true }
        return nil
    }
    // (chevron element, isExpanded) or nil when unreadable.
    func chevronState(_ row: AXUIElement) -> (AXUIElement, Bool)? {
        let cells = read(row, "AXChildren") as? [AXUIElement] ?? []
        for cell in cells {
            if let s = chevronStateText(cell) { return (cell, s) }
            let kids = read(cell, "AXChildren") as? [AXUIElement] ?? []
            for kid in kids {
                if let s = chevronStateText(kid) { return (kid, s) }
            }
        }
        return nil
    }
    guard let (tri0, _) = chevronState(row), frame(tri0) != nil else { print("target row has no usable chevron (Expand/Collapse label): \(rowName)"); exit(6) }
    var latMs = [Double](), jank = 0, inconclusive = 0, degradedEvents = 0
    for rep in 0..<reps {
        // Disclosure STATE must be a valid Bool before any input - a missing or
        // failed read aborts the run rather than defaulting to false.
        guard let (tri, disclosing) = chevronState(row) else {
            print("chevron state unreadable at rep \(rep) (unverified capability or stale handle); aborting"); exit(6)
        }
        let expectExpand = !disclosing
        guard let triFrame = frame(tri) else { print("chevron frame lost at rep \(rep)"); exit(6) }
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
        // Fresh state re-scan: expanded iff the chevron now reads "Collapse ...".
        let flippedState = chevronState(row).map { $0.1 }
        let stateFlipped = flippedState.map { $0 == expectExpand } ?? false
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
        "capability_note": "named-row/chevron-button (AXLabel Expand/Collapse <name>) mechanism unverified until the first successful expansion measurement",
        "expand_p50": percentile(latMs, 50), "expand_p95": percentile(latMs, 95),
        "jank_over_100ms": jank, "expansions_measured": latMs.count,
        "inconclusive_or_failed": inconclusive, "degraded_events": degradedEvents], inconclusive: inconclusive)
}
