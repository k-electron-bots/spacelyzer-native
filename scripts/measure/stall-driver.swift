// stall-driver.swift - bounded stall measurement driver (measurement-only, never shipped).
// Modes:
//   baseline <pid> <out.jsonl>        AX overhead baseline: repeated read-only attribute probes.
//   type <pid> <out.jsonl> <text>     Per-keystroke AX set+readback timing into the filter field.
//   expand <pid> <out.jsonl>          Two passes: menu proxy (AXShowMenu, NOT pointer hover,
//                                     menus dismissed via AXCancel between samples) + expand/
//                                     collapse top-level rows, round-trip timed.
//   nonascii <pid> <out.jsonl>        Non-ASCII value insert/readback probe only; NOT an IME
//                                     composition test (that gate stays open).
//   waitwindow <pid>                  Exit 0 when the app has an AX window (cold-launch marker).
// Times are wall-clock ms around the AX call (overhead-inclusive; the concurrent external
// `sample` capture is the overhead-free main-thread evidence).
import Foundation
import ApplicationServices
setbuf(stdout, nil)

func emit(_ path: String, _ line: String) {
    let url = URL(fileURLWithPath: path)
    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile(); h.write((line + "\n").data(using: .utf8)!); h.closeFile()
    }
}
func ms(_ t0: UInt64, _ t1: UInt64) -> Double {
    var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
    return Double(t1 - t0) * Double(info.numer) / Double(info.denom) / 1_000_000.0
}
func ax(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?; AXUIElementCopyAttributeValue(el, attr as CFString, &v); return v
}
func children(_ el: AXUIElement) -> [AXUIElement] {
    (ax(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}
func findRole(_ el: AXUIElement, role: String, depth: Int = 0) -> [AXUIElement] {
    if depth > 24 { return [] }
    var out: [AXUIElement] = []
    if (ax(el, kAXRoleAttribute) as? String) == role { out.append(el) }
    for c in children(el) { out.append(contentsOf: findRole(c, role: role, depth: depth + 1)) }
    return out
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[2]) else { print("usage"); exit(2) }
let mode = args[1]
let root = AXUIElementCreateApplication(pid)
guard AXIsProcessTrusted() else { print("ax-trust-denied"); exit(3) }

switch mode {
case "waitwindow":
    for _ in 0..<120 {
        let wins = ax(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        if !wins.isEmpty { print("window-ready"); exit(0) }
        Thread.sleep(forTimeInterval: 0.25)
    }
    exit(1)

case "baseline":
    let out = args[3]
    for i in 0..<100 {
        let t0 = mach_absolute_time()
        _ = ax(root, kAXRoleAttribute); _ = children(root)
        let t1 = mach_absolute_time()
        emit(out, "{\"probe\":\"baseline\",\"i\":\(i),\"ms\":\(ms(t0,t1))}")
    }
    print("baseline-done")

case "type":
    let out = args[3]; let text = args.count > 4 ? args[4] : "keep-tag-0001"
    var field: AXUIElement?
    for _ in 0..<40 {
        field = findRole(root, role: kAXTextFieldRole as String).first
        if field != nil { break }
        Thread.sleep(forTimeInterval: 0.5)
    }
    guard let f = field else { emit(out, "{\"probe\":\"type\",\"error\":\"no-filter-field\"}"); exit(1) }
    var typed = ""
    for (i, ch) in text.enumerated() {
        typed.append(ch)
        let t0 = mach_absolute_time()
        AXUIElementSetAttributeValue(f, kAXValueAttribute as CFString, typed as CFTypeRef)
        let readback = ax(f, kAXValueAttribute) as? String ?? ""
        let t1 = mach_absolute_time()
        emit(out, "{\"probe\":\"type\",\"i\":\(i),\"ms\":\(ms(t0,t1)),\"echoed\":\(readback == typed)}")
        Thread.sleep(forTimeInterval: 0.05)
    }
    AXUIElementSetAttributeValue(f, kAXValueAttribute as CFString, "" as CFTypeRef)
    print("type-done")

case "expand":
    let out = args[3]
    // Two passes over outline rows (24 samples). "menu" probe = AXShowMenu proxy for hover
    // cost (NOT pointer hover); each menu is dismissed with AXCancel between samples.
    var rows: [AXUIElement] = []
    for _ in 0..<40 {
        rows = findRole(root, role: kAXOutlineRole as String).flatMap { children($0) }
        if !rows.isEmpty { break }
        Thread.sleep(forTimeInterval: 0.5)
    }
    guard !rows.isEmpty else { emit(out, "{\"probe\":\"expand\",\"error\":\"no-rows\"}"); exit(1) }
    for pass in 0..<2 {
        for (i, row) in rows.prefix(12).enumerated() {
            let t0 = mach_absolute_time(); AXUIElementPerformAction(row, "AXShowMenu" as CFString); let t1 = mach_absolute_time()
            var dismissed = false
            for el in children(root) where (ax(el, kAXRoleAttribute) as? String) == "AXMenu" {
                AXUIElementPerformAction(el, "AXCancel" as CFString); dismissed = true
            }
            emit(out, "{\"probe\":\"menu\",\"pass\":\(pass),\"i\":\(i),\"ms\":\(ms(t0,t1)),\"dismissed\":\(dismissed)}")
            let t2 = mach_absolute_time()
            AXUIElementSetAttributeValue(row, kAXExpandedAttribute as CFString, true as CFTypeRef)
            let expanded = ax(row, kAXExpandedAttribute) as? Bool ?? false
            let t3 = mach_absolute_time()
            emit(out, "{\"probe\":\"expand\",\"pass\":\(pass),\"i\":\(i),\"ms\":\(ms(t2,t3)),\"expanded\":\(expanded)}")
            AXUIElementSetAttributeValue(row, kAXExpandedAttribute as CFString, false as CFTypeRef)
        }
    }
    print("expand-done")
case "cancel":
    let out = args[3]
    // Find a cancel-ish button mid-scan, press it, then measure post-cancel responsiveness.
    var btn: AXUIElement?
    for _ in 0..<60 {
        let buttons = findRole(root, role: kAXButtonRole as String)
        btn = buttons.first(where: {
            let t = ((ax($0, kAXTitleAttribute) as? String) ?? (ax($0, kAXDescriptionAttribute) as? String) ?? "").lowercased()
            return t.contains("cancel")
        })
        if btn != nil { break }
        Thread.sleep(forTimeInterval: 0.5)
    }
    guard let b = btn else { emit(out, "{\"probe\":\"cancel\",\"error\":\"no-cancel-button\"}") ; exit(1) }
    let t0 = mach_absolute_time()
    AXUIElementPerformAction(b, kAXPressAction as CFString)
    let t1 = mach_absolute_time()
    emit(out, "{\"probe\":\"cancel-press\",\"ms\":\(ms(t0,t1))}")
    Thread.sleep(forTimeInterval: 1.0)
    let t2 = mach_absolute_time()
    _ = ax(root, kAXRoleAttribute); _ = children(root)
    let t3 = mach_absolute_time()
    emit(out, "{\"probe\":\"cancel-post-responsive\",\"ms\":\(ms(t2,t3))}")
    print("cancel-done")

case "nonascii":
    let out = args[3]
    // Non-ASCII value-insert probe ONLY. This is NOT an IME marked-text composition test:
    // it measures insert/readback of a CJK string through the AX value attribute and nothing
    // more. The IME composition gate stays OPEN. Protocol-level composition harness
    // feasibility (NSTextInputClient insertText/setMarkedText/unmarkText) is assessed
    // separately; this probe makes no claim about whether the app can test composition.
    var field: AXUIElement?
    for _ in 0..<40 {
        field = findRole(root, role: kAXTextFieldRole as String).first
        if field != nil { break }
        Thread.sleep(forTimeInterval: 0.5)
    }
    guard let f = field else { emit(out, "{\"probe\":\"nonascii\",\"error\":\"no-filter-field\"}") ; exit(1) }
    let t0 = mach_absolute_time()
    AXUIElementSetAttributeValue(f, kAXValueAttribute as CFString, "\u{304b}\u{306a}keep" as CFTypeRef)
    let readback = ax(f, kAXValueAttribute) as? String ?? ""
    let t1 = mach_absolute_time()
    emit(out, "{\"probe\":\"nonascii\",\"ms\":\(ms(t0,t1)),\"nonascii_echoed\":\(readback == "\u{304b}\u{306a}keep")}")
    AXUIElementSetAttributeValue(f, kAXValueAttribute as CFString, "" as CFTypeRef)
    print("nonascii-done")

default:
    print("unknown mode"); exit(2)
}
