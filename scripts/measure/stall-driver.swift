// stall-driver.swift - bounded stall measurement driver (measurement-only, never shipped).
// Modes:
//   baseline <pid> <out.jsonl>        AX overhead baseline: repeated read-only attribute probes.
//   type <pid> <out.jsonl> <text>     Per-keystroke AX set+readback timing into the filter field.
//   expand <pid> <out.jsonl>          Two passes over the "Folder outline" AXTable rows:
//                                     menu proxy (AXShowMenu only when the row/cell exposes the
//                                     action AND a menu appears, NOT pointer hover, dismissed via
//                                     AXCancel) + chevron-press expand/collapse with verified
//                                     label-flip round trip. Unsupported/unverified -> error rows,
//                                     never timing samples.
//   nonascii <pid> <out.jsonl>        Non-ASCII value insert/readback probe only; NOT an IME
//                                     composition test (that gate stays open).
//   waitwindow <pid>                  Exit 0 when the app has an AX window (cold-launch marker).
// Times are wall-clock ms around the AX call (overhead-inclusive; the concurrent external
// `sample` capture is the overhead-free main-thread evidence).
// BOUNDEDNESS (run 38486848714 evidence: iteration-bounded polls overran wall-clock by 18 min
// because AX IPC waits on each call; per-call timeout x unbounded recursive call count is not a
// wall-clock bound): every driver start sets an explicit 3s messaging timeout process-globally,
// every mode runs under an in-process watchdog (exit 4), the workflow adds an external gtimeout,
// and stage/marker lines with epoch ms go to stdout so any future gap is localizable from the log.
// AX default-timeout semantics are NOT asserted (third-party docs describe a 6s system default;
// Apple's current page was not retrievable for confirmation); this driver never relies on it.
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

// Bound every AX IPC call: explicit 3s messaging timeout, process-global (SystemWide) and on the
// app ref. Never rely on a system default (semantics unverified - see header).
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 3.0)
AXUIElementSetMessagingTimeout(root, 3.0)
// In-process wall-clock watchdog: a blocked main thread cannot starve a background thread's exit.
let watchdog = Thread { Thread.sleep(forTimeInterval: 240); print("WATCHDOG-EXIT mode=\(CommandLine.arguments[1])"); exit(4) }
watchdog.start()
func marker(_ stage: String) {
    print("marker ts_ms=\(Int(Date().timeIntervalSince1970 * 1000)) mode=\(CommandLine.arguments[1]) stage=\(stage)")
}
marker("start")

switch mode {
case "waitwindow":
    for _ in 0..<120 {
        let wins = ax(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        if !wins.isEmpty { marker("waitwindow-found"); print("window-ready"); exit(0) }
        Thread.sleep(forTimeInterval: 0.25)
    }
    marker("waitwindow-timeout")
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
    // Product-true discovery (source-verified at 00aa46a2, mirrors scripts/ui-calibrate.swift):
    // the outline is an NSTableView (AXTable, AXDescription "Folder outline"), rows via AXRows.
    // Expand = AXPress on the per-row chevron NSButton (accessibilityDescription "Expand <name>"/
    // "Collapse <name>"); success = observed label flip within 2s, else the sample is an error row.
    // "menu" probe = AXShowMenu ONLY when the row/cell actually offers that action
    // (AXUIElementCopyActionNames); rows do have a context menu in source
    // (OutlineView.swift Coordinator.menu(for:) -> "Show in Finder"/"Check on disk"/"Move to Trash..."),
    // but if the action is not exposed or no menu appears, error rows are emitted - never timing samples.
    func table() -> AXUIElement? {
        var queue = children(root), seen = 0
        while !queue.isEmpty && seen < 256 {
            let el = queue.removeFirst(); seen += 1
            if (ax(el, kAXRoleAttribute) as? String) == "AXTable",
               (ax(el, "AXDescription") as? String) == "Folder outline" { return el }
            if (ax(el, kAXRoleAttribute) as? String) != "AXTable" { queue.append(contentsOf: children(el)) }
        }
        return nil
    }
    func rowsOf(_ t: AXUIElement) -> [AXUIElement] { (ax(t, "AXRows") as? [AXUIElement]) ?? [] }
    func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let n = names as? [String] else { return [] }
        return n
    }
    func chevron(_ row: AXUIElement, prefix: String) -> AXUIElement? {
        findRole(row, role: kAXButtonRole as String).first(where: {
            let d = (ax($0, "AXDescription") as? String) ?? (ax($0, kAXTitleAttribute) as? String) ?? ""
            return d.hasPrefix(prefix)
        })
    }
    var tbl: AXUIElement?
    for _ in 0..<90 {
        if let t = table(), !rowsOf(t).isEmpty { tbl = t; break }
        Thread.sleep(forTimeInterval: 1.0)
    }
    guard let t = tbl else { emit(out, "{\"probe\":\"expand\",\"error\":\"no-outline-table-or-rows\"}"); exit(1) }
    let rowCount = rowsOf(t).count
    // Row identity (mirrors scripts/ui-calibrate.swift): AXDescription, else the single child
    // description. Flip polls RE-FIND the row by identity on a fresh AXRows read - held refs can
    // go stale after virtualization/re-layout (run 38486848714: presses with no observable flip).
    func identity(_ row: AXUIElement) -> String {
        if let d = ax(row, "AXDescription") as? String, !d.isEmpty { return d }
        let kids = children(row).compactMap { ax($0, "AXDescription") as? String }.filter { !$0.isEmpty }
        return kids.count == 1 ? kids[0] : ""
    }
    func rowByIdentity(_ idn: String) -> AXUIElement? {
        rowsOf(t).first(where: { identity($0) == idn })
    }
    // Expandable rows = rows with a visible "Expand" chevron (chevron is hidden for childless rows,
    // OutlineView.swift:288). Pre-registered floor is n>=20 verified samples, so passes adapt to the
    // expandable-row count instead of assuming 12; a true shortfall stays INCONCLUSIVE by the floor.
    var expandable: [(Int, String)] = []
    for i in 0..<min(rowCount, 24) {
        if let row = rowsOf(t).dropFirst(i).first, chevron(row, prefix: "Expand") != nil {
            let idn = identity(row)
            if !idn.isEmpty { expandable.append((i, idn)) }
        }
    }
    let targets = Array(expandable.prefix(12))
    func jesc(_ v: String) -> String {
        v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    marker("expand-targets count=\(targets.count) of first-rows=\(min(rowCount, 24))")
    let expandPasses = targets.isEmpty ? 0 : max(2, min(6, (24 + targets.count - 1) / targets.count))
    if targets.isEmpty { emit(out, "{\"probe\":\"expand\",\"error\":\"no-expandable-rows\"}") }
    // menu proxy with runtime support verification
    var menuSupportChecked = false, menuSupported = false, menuOnCell = false
    for pass in 0..<2 {
        for i in 0..<min(12, rowCount) {
            guard let row = rowsOf(t).dropFirst(i).first else { continue }
            if !menuSupportChecked {
                menuSupportChecked = true
                if actions(row).contains("AXShowMenu") { menuSupported = true }
                else if let cell = children(row).first, actions(cell).contains("AXShowMenu") { menuSupported = true; menuOnCell = true }
            }
            if !menuSupported { if pass == 0 && i == 0 { marker("menu-showmenu-not-exposed"); emit(out, "{\"probe\":\"menu\",\"error\":\"showmenu-action-not-exposed\"}") }; continue }
            let target = menuOnCell ? (children(row).first ?? row) : row
            let t0 = mach_absolute_time(); AXUIElementPerformAction(target, "AXShowMenu" as CFString); let t1 = mach_absolute_time()
            var seen = false, dismissed = false
            for _ in 0..<8 {
                for el in children(root) where (ax(el, kAXRoleAttribute) as? String) == "AXMenu" {
                    seen = true
                    AXUIElementPerformAction(el, "AXCancel" as CFString); dismissed = true
                }
                if seen { break }; Thread.sleep(forTimeInterval: 0.1)
            }
            if seen { emit(out, "{\"probe\":\"menu\",\"pass\":\(pass),\"i\":\(i),\"ms\":\(ms(t0,t1)),\"dismissed\":\(dismissed)}") }
            else { emit(out, "{\"probe\":\"menu\",\"pass\":\(pass),\"i\":\(i),\"error\":\"menu-not-shown\"}") }
        }
    }
    // expand/collapse with verified state flip (adaptive passes; fresh identity-matched refs)
    for pass in 0..<expandPasses {
        marker("expand-pass-start pass=\(pass)")
        for (i, idn) in targets {
            guard let row = rowByIdentity(idn) else {
                emit(out, "{\"probe\":\"expand\",\"pass\":\(pass),\"i\":\(i),\"error\":\"row-identity-lost\"}")
                continue
            }
            guard let btn = chevron(row, prefix: "Expand") else { continue }  // no children or already expanded
            let t0 = mach_absolute_time()
            AXUIElementPerformAction(btn, kAXPressAction as CFString)
            var flipped = false; var t1 = t0
            for _ in 0..<20 {
                if let fresh = rowByIdentity(idn), chevron(fresh, prefix: "Collapse") != nil { flipped = true; t1 = mach_absolute_time(); break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if flipped { emit(out, "{\"probe\":\"expand\",\"pass\":\(pass),\"i\":\(i),\"ms\":\(ms(t0,t1)),\"verified\":true,\"id\":\"\(jesc(idn))\"}") }
            else { emit(out, "{\"probe\":\"expand\",\"pass\":\(pass),\"i\":\(i),\"error\":\"expand-unverified-2s\",\"id\":\"\(jesc(idn))\"}") }
            // collapse back (best-effort, untimed, fresh refs) so the next pass sees the same state
            if let fresh = rowByIdentity(idn), let cb = chevron(fresh, prefix: "Collapse") {
                AXUIElementPerformAction(cb, kAXPressAction as CFString)
                for _ in 0..<20 { if let f2 = rowByIdentity(idn), chevron(f2, prefix: "Expand") != nil { break }; Thread.sleep(forTimeInterval: 0.1) }
            }
        }
    }
    marker("expand-done")
    print("expand-done")

case "cancel":
    let out = args[3]
    // Product-true discovery (ContentView.swift:54): the mid-scan control is titled "Stop" with
    // accessibilityLabel "Stop scan", present only while model.scanning. "Cancel" exists only on
    // removal-confirmation dialogs - matching it would be a wrong-control press. Poll from launch:
    // a fast runner scan is short, and a missed window is an honest error row, never a fake press.
    var btn: AXUIElement?
    for _ in 0..<240 {
        let buttons = findRole(root, role: kAXButtonRole as String)
        btn = buttons.first(where: {
            let t = ((ax($0, "AXDescription") as? String) ?? "").lowercased()
            let ti = ((ax($0, kAXTitleAttribute) as? String) ?? "").lowercased()
            return t.contains("stop") || ti.contains("stop")
        })
        if btn != nil { break }
        Thread.sleep(forTimeInterval: 0.25)
    }
    guard let b = btn else { marker("cancel-window-missed"); emit(out, "{\"probe\":\"cancel\",\"error\":\"no-stop-button-scan-window-missed\"}") ; exit(1) }
    marker("cancel-stop-found")
    let t0 = mach_absolute_time()
    AXUIElementPerformAction(b, kAXPressAction as CFString)
    let t1 = mach_absolute_time()
    marker("cancel-pressed")
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
