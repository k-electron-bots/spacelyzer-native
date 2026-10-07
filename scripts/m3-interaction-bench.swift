import Foundation
import AppKit
import ApplicationServices
import Darwin

// Milestone 3 interaction bench: measures typing, hover, and huge-folder
// expansion latency through external AX queries plus ordinary mouse/key input,
// exactly the envelope ui-calibrate.swift declares (no attribute writes, no
// menus/Trash, disposable fixtures only). Runs ONLY inside an approved
// measurement run. Raw per-event JSONL goes to the output path; a summary
// object (p50/p95, jank counts) prints to stdout as the last line.
//
//   m3-interaction-bench typing    <pid> <out.jsonl> [keystrokes=200]
//   m3-interaction-bench hover     <pid> <out.jsonl> [sweeps=60]
//   m3-interaction-bench expansion <pid> <out.jsonl> <rowName> [reps=5]
//
// Exit codes: 2 usage, 3 AX trust, 4 landmarks, 5 window geometry,
// 6 target row/triangle, 7 typing focus, 8 output file.

let args = CommandLine.arguments
guard args.count >= 4, let pid = Int32(args[2]) else {
    print("usage: m3-interaction-bench <typing|hover|expansion> <pid> <out.jsonl> [args]"); exit(2)
}
let mode = args[1]
let outPath = args[3]
guard AXIsProcessTrusted() else { print("BLOCKED AX trust unavailable; not a measurement"); exit(3) }
guard FileManager.default.createFile(atPath: outPath, contents: nil),
      let out = FileHandle(forWritingAtPath: outPath) else { print("cannot open output \(outPath)"); exit(8) }

let app = AXUIElementCreateApplication(pid)
func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}
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
func rowCount(_ table: AXUIElement) -> Int? {
    var count: CFIndex = 0
    return AXUIElementGetAttributeValueCount(table, "AXRows" as CFString, &count) == .success ? count : nil
}
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func until(_ seconds: Double, interval: UInt32 = 10_000, _ condition: () -> Bool) -> Double? {
    let start = now(), deadline = start + seconds
    repeat { if condition() { return (now() - start) * 1000 } ; usleep(interval) } while now() < deadline
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
func key(_ virtualKey: UInt16) { // real key event: delete, arrows, etc.
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
    if let data = try? JSONSerialization.data(withJSONObject: object) {
        out.write(data); out.write(Data([0x0a]))
    }
}

// Shared landmarks (same names ui-calibrate.swift pins).
guard let running = NSRunningApplication(processIdentifier: pid), running.activate(),
      until(5, interval: 250_000, { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }) != nil,
      until(30, interval: 250_000, { one("AXTable", "Folder outline") != nil && one("AXTextField", "Filter by name") != nil }) != nil,
      let table = one("AXTable", "Folder outline"), let field = one("AXTextField", "Filter by name"),
      let fieldFrame = frame(field), let tableFrame = frame(table) else { exit(4) }
let windows = read(app, "AXWindows") as? [AXUIElement] ?? []
guard windows.count == 1, let winFrame = frame(windows[0]), winFrame.width > 0 else { exit(5) }

if mode == "typing" {
    let n = args.count > 4 ? Int(args[4]) ?? 200 : 200
    click(CGPoint(x: fieldFrame.midX, y: fieldFrame.midY))
    guard until(2, { string(field, "AXFocused") == "1" || (read(field, "AXFocused") as? Bool) == true }) != nil else {
        print("filter field did not take focus after click"); exit(7)
    }
    let stream = Array("invoice backup photo archive render cache export draft ")
    var fieldMs = [Double](), resultMs = [Double]()
    var typed = ""
    for i in 0..<n {
        let ch = stream[i % stream.count]
        typed.append(ch)
        let rowsBefore = rowCount(table) ?? -1
        let t0 = now()
        type(ch)
        let f = until(2, { string(field, "AXValue").hasSuffix(String(ch)) && string(field, "AXValue").count >= typed.count })
        // Result-list update: row count changes, or three consecutive stable polls
        // prove the current filter changed nothing visible (marked no_change).
        var r: Double? = nil, noChange = false
        if let v = until(2, { (rowCount(table) ?? -1) != rowsBefore }) { r = v }
        else {
            let settleStart = now()
            var last = rowCount(table) ?? -1, stable = 0
            while now() - settleStart < 2 {
                usleep(20_000)
                let c = rowCount(table) ?? -1
                stable = c == last ? stable + 1 : 0
                last = c
                if stable >= 3 { noChange = true; break }
            }
        }
        emit(["event": "key", "i": i, "char": String(ch), "field_ms": f ?? -1,
              "results_ms": r ?? -1, "no_change": noChange, "t_rel_ms": (now() - t0) * 1000])
        if let f { fieldMs.append(f) }
        if let r { resultMs.append(r) }
        usleep(30_000) // ~33 keys/s: fast typist, keeps the debouncer honest
        if typed.count >= 24 { // keep the filter short: clear with key events only
            for _ in typed { key(kDelete); usleep(5_000) }
            typed = ""
            _ = until(2, { string(field, "AXValue").isEmpty })
        }
    }
    fieldMs.sort(); resultMs.sort()
    let summary: [String: Any] = ["kind": "m3-typing", "pid": pid, "n": n,
        "field_p50": percentile(fieldMs, 50), "field_p95": percentile(fieldMs, 95),
        "results_p50": percentile(resultMs, 50), "results_p95": percentile(resultMs, 95),
        "timeouts_field": n - fieldMs.count, "timeouts_results": n - resultMs.count]
    if let data = try? JSONSerialization.data(withJSONObject: summary) { print(String(data: data, encoding: .utf8)!) }
    exit(0)
}

if mode == "hover" {
    let sweeps = args.count > 4 ? Int(args[4]) ?? 60 : 60
    // Sweep a grid over the window content: treemap region and outline rows both
    // fall under the pointer; the element under the pointer identifies which.
    var lagMs = [Double](), over100 = 0
    let cols = 6, rows = 4
    for s in 0..<sweeps {
        let gx = s % cols, gy = (s / cols) % rows
        let x = winFrame.minX + winFrame.width * (0.1 + 0.8 * Double(gx) / Double(cols - 1))
        let y = winFrame.minY + winFrame.height * (0.15 + 0.75 * Double(gy) / Double(rows - 1))
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .leftMouse)?.post(tap: .cghidEventTap)
        var element: AXUIElement?
        let lag = until(1, {
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(app, Float(x), Float(y), &hit) == .success, let hit {
                element = hit; return true
            }
            return false
        })
        let role = element.map { string($0, "AXRole") } ?? "none"
        let ms = lag ?? -1
        emit(["event": "hover", "sweep": s, "x": x, "y": y, "element_role": role, "lag_ms": ms])
        if let lag { lagMs.append(lag); if lag > 100 { over100 += 1 } }
        usleep(50_000)
    }
    lagMs.sort()
    let summary: [String: Any] = ["kind": "m3-hover", "pid": pid, "sweeps": sweeps,
        "lag_p50": percentile(lagMs, 50), "lag_p95": percentile(lagMs, 95),
        "over_100ms": over100, "timeouts": sweeps - lagMs.count]
    if let data = try? JSONSerialization.data(withJSONObject: summary) { print(String(data: data, encoding: .utf8)!) }
    exit(0)
}

if mode == "expansion" {
    guard args.count >= 5 else { print("expansion needs <rowName>"); exit(2) }
    let rowName = args[4]
    let reps = args.count > 5 ? Int(args[5]) ?? 5 : 5
    let visibleRows = { read(table, "AXRows") as? [AXUIElement] ?? [] }
    func findRow() -> AXUIElement? {
        visibleRows().first { row in
            if string(row, "AXDescription") == rowName { return true }
            let cells = read(row, "AXChildren") as? [AXUIElement] ?? []
            return cells.contains { string($0, "AXDescription") == rowName || string($0, "AXValue") == rowName }
        }
    }
    func triangle(_ row: AXUIElement) -> AXUIElement? {
        let cells = read(row, "AXChildren") as? [AXUIElement] ?? []
        for cell in cells where string(cell, "AXRole") == "AXDisclosureTriangle" { return cell }
        return string(row, "AXRole") == "AXDisclosureTriangle" ? row : nil
    }
    guard let row0 = findRow(), let tri0 = triangle(row0), frame(tri0) != nil else {
        print("target row or its disclosure triangle not found: \(rowName)"); exit(6)
    }
    var latMs = [Double](), jank = 0
    for rep in 0..<reps {
        guard let row = findRow(), let tri = triangle(row), let triFrame = frame(tri) else { exit(6) }
        let before = rowCount(table) ?? -1
        let expectExpand = rep % 2 == 0 // reps alternate expand, collapse, expand...
        click(CGPoint(x: triFrame.midX, y: triFrame.midY))
        let lat = until(30, { // 1m children can legitimately take seconds
            let c = rowCount(table) ?? -1
            return expectExpand ? c > before : (c >= 0 && c < before)
        })
        let after = rowCount(table) ?? -1
        let expanded = after > before
        let ms = lat ?? -1
        if expanded, let lat { latMs.append(lat); if lat > 100 { jank += 1 } }
        emit(["event": "expansion", "rep": rep, "rows_before": before, "rows_after": after,
              "expanded": expanded, "latency_ms": ms, "jank_over_100ms": expanded && lat != nil && lat! > 100])
        usleep(500_000)
    }
    latMs.sort()
    let summary: [String: Any] = ["kind": "m3-expansion", "pid": pid, "row": rowName, "reps": reps,
        "latency_p50": percentile(latMs, 50), "latency_p95": percentile(latMs, 95),
        "jank_over_100ms": jank, "expansions_seen": latMs.count]
    if let data = try? JSONSerialization.data(withJSONObject: summary) { print(String(data: data, encoding: .utf8)!) }
    exit(0)
}

print("unknown mode \(mode)"); exit(2)
