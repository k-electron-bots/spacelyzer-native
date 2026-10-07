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
// WHAT THIS MEASURES: event-to-AX-visible latency - input event to the expected
// change being observable through AX. That is user-visible jank evidence, NOT
// proof the main thread was blocked (AX callbacks, coalescing, and scheduling
// also add delay). Synchronous AX reads can themselves stall, so every AX read
// is timed and logged; a stall in a read confounds the event it serves and is
// visible in the log. Main-thread blocked time needs separate in-app
// instrumentation and is not claimed here.
//
//   m3-interaction-bench typing    <pid> <out.jsonl> [keystrokes=200]
//   m3-interaction-bench hover     <pid> <out.jsonl> [sweeps=60]
//   m3-interaction-bench expansion <pid> <out.jsonl> <rowName> [reps=5]
//
// PREFLIGHT (external, documented not enforced by this tool): the operator scans
// the fixture PROFILE directory directly (ROOT/typing-200k or ROOT/expansion-N,
// per scripts/make_fixtures.py verify) in the target app before measuring. The
// harness verifies what is AX-visible before any input: landmarks present,
// filter field initially empty (typing), target row present and unique
// (expansion). It cannot verify the scanned path - AX does not expose it.
//
// Exit codes: 2 usage/args, 3 AX trust, 4 landmarks/frontmost, 5 window geometry,
// 6 target row/triangle, 7 focus/field-state, 8 output file, 9 log write failure.

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("usage: m3-interaction-bench <typing|hover|expansion> <pid> <out.jsonl> [args]"); exit(2)
}
let mode = args[1]
guard mode == "typing" || mode == "hover" || mode == "expansion" else { print("unknown mode \(mode)"); exit(2) }
guard let pid = Int32(args[2]), pid > 0 else { print("bad pid"); exit(2) }
let outPath = args[3]
// Validate every mode argument BEFORE touching the output file.
var keystrokes = 200, sweeps = 60, reps = 5, rowName = ""
switch mode {
case "typing":
    if args.count > 4 { guard let v = Int(args[4]), v > 0 else { print("keystrokes must be > 0"); exit(2) }; keystrokes = v }
case "hover":
    if args.count > 4 { guard let v = Int(args[4]), v > 0 else { print("sweeps must be > 0"); exit(2) }; sweeps = v }
default:
    guard args.count >= 5, !args[4].isEmpty else { print("expansion needs <rowName>"); exit(2) }
    rowName = args[4]
    if args.count > 5 { guard let v = Int(args[5]), v > 0 else { print("reps must be > 0"); exit(2) }; reps = v }
}
guard !FileManager.default.fileExists(atPath: outPath) else { print("REFUSED: \(outPath) exists; logs are never overwritten"); exit(8) }
guard FileManager.default.createFile(atPath: outPath, contents: nil),
      let out = FileHandle(forWritingAtPath: outPath) else { print("cannot open output \(outPath)"); exit(8) }
guard AXIsProcessTrusted() else { print("BLOCKED AX trust unavailable; not a measurement"); exit(3) }

let app = AXUIElementCreateApplication(pid)
var axReadFailures = 0
func now() -> Double { ProcessInfo.processInfo.systemUptime }
// Every AX read is timed: a synchronous AX stall confounds the event it serves.
func readTimed(_ element: AXUIElement, _ name: String) -> (CFTypeRef?, Double) {
    let start = now()
    var result: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, name as CFString, &result)
    if err != .success && err != .attributeUnsupported && err != .noValue { axReadFailures += 1 }
    return (err == .success ? result : nil, (now() - start) * 1000)
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
// Count-only row read: never materializes the AXRows array (a 1m-child expansion
// would otherwise build a 1m-element array per poll).
func rowCountTimed(_ table: AXUIElement) -> (Int?, Double) {
    let start = now()
    var count: CFIndex = 0
    let err = AXUIElementGetAttributeValueCount(table, "AXRows" as CFString, &count)
    if err != .success && err != .attributeUnsupported && err != .noValue { axReadFailures += 1 }
    return (err == .success ? Int(count) : nil, (now() - start) * 1000)
}
// Elapsed is always measured from the caller's t0, taken BEFORE the input event.
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
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .leftMouse)?.post(tap: .cghidEventTap)
    usleep(40_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .leftMouse)?.post(tap: .cghidEventTap)
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

// Shared landmarks (same names ui-calibrate.swift pins), before any input.
guard let running = NSRunningApplication(processIdentifier: pid), running.activate(),
      until(now(), 5, interval: 250_000, { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }) != nil,
      until(now(), 30, interval: 250_000, { one("AXTable", "Folder outline") != nil && one("AXTextField", "Filter by name") != nil }) != nil,
      let table = one("AXTable", "Folder outline"), let field = one("AXTextField", "Filter by name"),
      let fieldFrame = frame(field) else { exit(4) }
let windows = read(app, "AXWindows") as? [AXUIElement] ?? []
guard windows.count == 1, let winFrame = frame(windows[0]), winFrame.width > 0 else { exit(5) }
func frontmostAndFocused(_ field: AXUIElement) -> Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && (read(field, "AXFocused") as? Bool) == true
}
func summary(_ object: [String: Any]) -> Never {
    var withCommon = object
    withCommon["ax_read_failures"] = axReadFailures
    withCommon["limitation"] = "event-to-AX-visible latency only; not proof of main-thread block"
    emit(withCommon)
    guard let data = try? JSONSerialization.data(withJSONObject: withCommon) else { exit(9) }
    print(String(data: data, encoding: .utf8) ?? "")
    exit(0)
}
emit(["header": "m3-interaction-bench", "mode": mode, "pid": pid,
      "limitation": "event-to-AX-visible latency only; not proof of main-thread block",
      "preflight": "operator scanned the fixture profile dir directly; harness verifies AX-visible state only"])

if mode == "typing" {
    // Preflight: the filter field must start EMPTY - a dirty field makes every
    // per-key expectation wrong.
    guard string(field, "AXValue").isEmpty else { print("filter field not empty at start; not measuring"); exit(7) }
    click(CGPoint(x: fieldFrame.midX, y: fieldFrame.midY))
    guard until(now(), 2, { frontmostAndFocused(field) }) != nil else { print("filter field did not take focus"); exit(7) }
    let stream = Array("invoice backup photo archive render cache export draft ")
    var fieldMs = [Double](), resultMs = [Double](), fieldTimeouts = 0, resultInconclusive = 0
    var typed = ""
    for i in 0..<keystrokes {
        // Focus/frontmost recheck BEFORE every key batch (and before the delete batch below).
        guard frontmostAndFocused(field) else { print("focus lost before key \(i); aborting"); exit(7) }
        let ch = stream[i % stream.count]
        let expected = typed + String(ch)
        let (rowsBefore, beforeReadMs) = rowCountTimed(table)
        let t0 = now()
        type(ch)
        // Field: exact full-string equality, never a suffix match.
        var lastFieldReadMs = -1.0
        let f = until(t0, 2, {
            let (v, ms) = readTimed(field, "AXValue"); lastFieldReadMs = ms
            return (v as? String) == expected
        })
        // Results: row-count change from the pre-key baseline. No settle claim:
        // an unchanged count at deadline (or a failed count read) is INCONCLUSIVE.
        var lastCountReadMs = -1.0
        let r = until(t0, 2, {
            let (c, ms) = rowCountTimed(table); lastCountReadMs = ms
            guard let c, let rowsBefore else { return false }
            return c != rowsBefore
        })
        let verdict = r != nil ? "updated" : "inconclusive"
        emit(["event": "key", "i": i, "char": String(ch), "expected_field": expected,
              "field_ms": f ?? -1, "results_ms": r ?? -1, "results_verdict": verdict,
              "rows_before": rowsBefore ?? -1, "read_ms_before": beforeReadMs,
              "read_ms_field": lastFieldReadMs, "read_ms_count": lastCountReadMs])
        if let f { fieldMs.append(f) } else { fieldTimeouts += 1 }
        if let r { resultMs.append(r) } else { resultInconclusive += 1 }
        usleep(30_000) // serial-latency mode: one key measured at a time; no rate claim
        if typed.count + 1 >= 24 { // keep the filter short; clear with real delete-key events
            guard frontmostAndFocused(field) else { print("focus lost before delete batch; aborting"); exit(7) }
            for _ in 0..<(typed.count + 1) { key(kDelete); usleep(5_000) }
            typed = ""
            guard until(now(), 2, { string(field, "AXValue").isEmpty }) != nil else {
                print("filter field failed to clear; aborting"); exit(7)
            }
        } else {
            typed.append(ch)
        }
    }
    fieldMs.sort(); resultMs.sort()
    summary(["kind": "m3-typing", "pid": pid, "n": keystrokes, "mode_note": "serial per-key latency; not a burst/typist-rate measurement",
        "field_p50": percentile(fieldMs, 50), "field_p95": percentile(fieldMs, 95),
        "results_p50": percentile(resultMs, 50), "results_p95": percentile(resultMs, 95),
        "field_timeouts": fieldTimeouts, "results_inconclusive": resultInconclusive])
}

if mode == "hover" {
    // AX HIT-TEST request latency only: how long until the element under the new
    // pointer position resolves. No hover-render or highlight causality is claimed.
    var lagMs = [Double](), queryMs = [Double](), over100 = 0, timeouts = 0
    let cols = 6, rows = 4
    for s in 0..<sweeps {
        let gx = s % cols, gy = (s / cols) % rows
        let x = winFrame.minX + winFrame.width * (0.1 + 0.8 * Double(gx) / Double(cols - 1))
        let y = winFrame.minY + winFrame.height * (0.15 + 0.75 * Double(gy) / Double(rows - 1))
        let t0 = now() // anchor BEFORE the posted move
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .leftMouse)?.post(tap: .cghidEventTap)
        var role = "none", qMs = -1.0
        let lag = until(t0, 1, {
            var hit: AXUIElement?
            let q0 = now()
            let err = AXUIElementCopyElementAtPosition(app, Float(x), Float(y), &hit)
            qMs = (now() - q0) * 1000
            if err != .success && err != .noValue && err != .attributeUnsupported { axReadFailures += 1 }
            guard err == .success, let hit else { return false }
            role = string(hit, "AXRole")
            return true
        })
        emit(["event": "hover", "sweep": s, "x": x, "y": y, "element_role": role,
              "hittest_ms": lag ?? -1, "ax_query_ms": qMs])
        if let lag { lagMs.append(lag); queryMs.append(qMs); if lag > 100 { over100 += 1 } } else { timeouts += 1 }
        usleep(50_000)
    }
    lagMs.sort(); queryMs.sort()
    summary(["kind": "m3-hover-ax-hittest", "pid": pid, "sweeps": sweeps,
        "note": "AX hit-test request latency only; no hover-render or highlight causality",
        "hittest_p50": percentile(lagMs, 50), "hittest_p95": percentile(lagMs, 95),
        "ax_query_p50": percentile(queryMs, 50), "ax_query_p95": percentile(queryMs, 95),
        "over_100ms": over100, "timeouts": timeouts])
}

if mode == "expansion" {
    // Target lookup happens BEFORE expansion, while the visible row set is small;
    // polling afterwards is count-only (rowCountTimed) and never materializes
    // the expanded AXRows array.
    func findTarget() -> AXUIElement? {
        let rows = read(table, "AXRows") as? [AXUIElement] ?? []
        let matches = rows.filter { row in
            if string(row, "AXDescription") == rowName { return true }
            let cells = read(row, "AXChildren") as? [AXUIElement] ?? []
            return cells.contains { string($0, "AXDescription") == rowName || string($0, "AXValue") == rowName }
        }
        return matches.count == 1 ? matches[0] : nil
    }
    guard let row0 = findTarget() else { print("target row not unique or absent: \(rowName)"); exit(6) }
    let cells0 = read(row0, "AXChildren") as? [AXUIElement] ?? []
    guard cells0.contains(where: { string($0, "AXRole") == "AXDisclosureTriangle" }) || string(row0, "AXRole") == "AXDisclosureTriangle" else {
        print("target row has no disclosure triangle: \(rowName)"); exit(6)
    }
    var latMs = [Double](), jank = 0, timeouts = 0, failedOps = 0
    for rep in 0..<reps {
        guard let row = findTarget() else { print("target lost at rep \(rep)"); exit(6) }
        let cells = read(row, "AXChildren") as? [AXUIElement] ?? []
        guard let tri = (cells.first { string($0, "AXRole") == "AXDisclosureTriangle" } ?? (string(row, "AXRole") == "AXDisclosureTriangle" ? row : nil)),
              let triFrame = frame(tri) else { exit(6) }
        // Disclosure STATE decides the expectation - never rep parity.
        let (disclosingV, disclosingReadMs) = readTimed(row, "AXDisclosing")
        let expectExpand = (disclosingV as? Bool) != true
        let (rowsBefore, beforeReadMs) = rowCountTimed(table)
        guard let rowsBefore else { print("row count unreadable at rep \(rep)"); failedOps += 1; continue }
        let t0 = now()
        click(CGPoint(x: triFrame.midX, y: triFrame.midY))
        var maxPollReadMs = 0.0
        let lat = until(t0, 30, { // 1m children can legitimately take seconds
            let (c, ms) = rowCountTimed(table); maxPollReadMs = max(maxPollReadMs, ms)
            guard let c else { return false }
            return expectExpand ? c > rowsBefore : c < rowsBefore
        })
        let (rowsAfter, afterReadMs) = rowCountTimed(table)
        let (disclosedAfterV, _) = readTimed(row, "AXDisclosing")
        // A failed state read is never a flip: require a non-nil value.
        let stateFlipped = (disclosedAfterV as? Bool).map { $0 == expectExpand } ?? false
        let countMoved = rowsAfter.map { expectExpand ? $0 > rowsBefore : $0 < rowsBefore } ?? false
        let ok = lat != nil && countMoved && stateFlipped
        if !ok { failedOps += 1 }
        if lat == nil { timeouts += 1 }
        if ok, expectExpand, let lat { latMs.append(lat); if lat > 100 { jank += 1 } }
        emit(["event": expectExpand ? "expand" : "collapse", "rep": rep, "rows_before": rowsBefore,
              "rows_after": rowsAfter ?? -1, "latency_ms": lat ?? -1, "ok": ok,
              "state_flipped": stateFlipped, "jank_over_100ms": ok && expectExpand && (lat ?? 0) > 100,
              "read_ms_before": beforeReadMs, "read_ms_after": afterReadMs,
              "read_ms_disclosing": disclosingReadMs, "read_ms_poll_max": maxPollReadMs])
        usleep(500_000)
    }
    latMs.sort()
    summary(["kind": "m3-expansion", "pid": pid, "row": rowName, "reps": reps,
        "expand_p50": percentile(latMs, 50), "expand_p95": percentile(latMs, 95),
        "jank_over_100ms": jank, "expansions_measured": latMs.count,
        "timeouts": timeouts, "failed_ops": failedOps])
}
