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
//   watch <pid> <out.jsonl> [cap-s]   Passive scan-window observation (DIAGNOSTIC launches only):
//                                     1 Hz Stop-button presence poll (the control exists only
//                                     mid-scan), no presses, no value sets. Exits at scan-window
//                                     close + 10s settle, or at the cap (default 60s).
//   cancelrecover <pid> <out.jsonl> <fixture> <sentinel> <sentinelChild>
//                                     Product-true cancel + recovery, per sample on a FRESH
//                                     instance launched with SPZ_AUTOSCAN=<fixture>:
//                                     (1) ACTIVATION: press the mid-scan "Stop" toolbar control
//                                     (ContentView.swift:44, present only while model.scanning;
//                                     discovery identical to "cancel") and require its
//                                     disappearance - a responsive button alone is not evidence;
//                                     a press with no observed activation is INCONCLUSIVE (AX
//                                     press delivery vs product behavior is indistinguishable).
                                     Discovery polls from t~0 (window wait folded in) with
                                     per-iteration AX-walk latency OBS buckets, so a
                                     starved-AX run is measured, not silent (run 38773486853:
                                     three silent 150s external-watchdog burns).
//                                     (2) CANCELLED STATE: the StatusBar AX carrier (a bare Text
//                                     bridging fullDetails as AXValue+AXHelp on one AXStaticText;
//                                     ContentView.swift StatusBar .background carrier, run
//                                     37971834595 client log) must reach "Scanned in" WITH
//                                     "Stopped early, partial accounting" and root line == fixture.
//                                     "Scanned in" WITHOUT "Stopped early" = the scan completed
//                                     before the press landed = INCONCLUSIVE, never a silent pass.
//                                     press->terminal interval = per-sample cancel-latency
//                                     observation (proposed engineering ceiling 1000ms/sample;
//                                     the independent reviewer judges measurement validity).
//                                     (3) RECOVERY: toolbar "Scan" menu -> "Home Folder"; the
//                                     follow-up scan must publish its OWN tree (terminal footer
//                                     with root line != fixture, no "Stopped early"), show the
//                                     workflow-planted sentinel row, and expand it to its known
//                                     child. The runner Home workload is uncontrolled, so an
//                                     unmet recovery deadline is INCONCLUSIVE "deadline-not-met"
//                                     with the last observed footer state, never a stall claim;
//                                     FAIL is reserved for contradictory state/count/tree.
//                                     (4) OLD WORK MUST NOT OVERWRITE: the terminal footer
//                                     is re-read twice over a 6s settle; any text change, a root
//                                     line flip back to the fixture, or a fixture-magnitude item
//                                     count (>= 1,000,000) is a FAIL.
//   publish1m <pid> <out.jsonl> [expectTop expectItems firstRow lastRow expandRow expectChildren]
//                                     1M-entry publication on a FRESH instance launched with
//                                     SPZ_AUTOSCAN=<fixture>. INTERVAL (declared; NOT the
//                                     pre-registered 250ms expand interaction bar and NOT an
//                                     engine-side timing): starts at driver attach (mode start,
//                                     immediately after app launch; open+bind+spawn ~1-3s is
//                                     INCLUDED, so this is an upper-bound observation of
//                                     launch->published) and ends when the terminal footer state
//                                     AND the known outline rows are both observed. VISIBLE
//                                     SUCCESS STATE (all required): footer "Scanned in" with no
//                                     "Scanning:" and no "Stopped early"; footer item count ==
//                                     expectItems; outline AXTable row count == expectTop with
//                                     firstRow/lastRow present (order-free membership).
//                                     DEADLINE: 30s from attach is an engineering smoke deadline
//                                     with >3x margin over the ~4-10s engine scans measured on
//                                     this runner class (run 38458610451) - NOT a performance
//                                     bar. Exceeding it is INCONCLUSIVE "deadline-not-met" with
//                                     the last observed footer state as evidence: a still-
//                                     "Scanning:" or unreadable carrier proves neither stall
//                                     nor product breakage (workload/AX are uncontrolled). FAIL
//                                     is reserved for contradictory state/count/tree. POSITIVE
//                                     CLOSURE IS LIMITED: PASS closes a 1M-entry scan publishing
//                                     its footer state plus 200 top-level outline rows - it does
//                                     NOT close 1M-sibling publication/render. Budget/watchdog
//                                     clips stay INCONCLUSIVE. 1 Hz AX read samples during the
//                                     wait and a single d150 chevron flip afterwards are
//                                     OBSERVATIONS ONLY, never gated, and do not re-open the
//                                     pre-registered expansion target.
                                     The window wait is folded into the publication wait:
                                     polling starts at t0 and each second's AX-walk latency is
                                     printed as an OBS sample (starvation measurement).
// Times are wall-clock ms around the AX call (overhead-inclusive; the concurrent external
// `sample` capture is the overhead-free main-thread evidence).
// BOUNDEDNESS (run 38486848714 evidence: iteration-bounded polls overran wall-clock by 18 min
// because AX IPC waits on each call; per-call timeout x unbounded recursive call count is not a
// wall-clock bound): every driver start sets an explicit 3s messaging timeout process-globally,
// every mode runs under an in-process watchdog (exit 4), the workflow adds an external pure-bash watchdog,
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

// readiness-driver additions: shared helpers for cancelrecover / publish1m. Existing modes above
// are byte-preserved from the reviewed stall-driver (their verdicts and discovery are unchanged).
// detailsCarrier: the StatusBar carries the exact fullDetails string on ONE AXStaticText node as
// AXValue+AXHelp (ContentView.swift StatusBar .background carrier; run 37971834595 client log).
// Only AXStaticText nodes are text-read, so a walk costs ~2 AX calls per non-text element.
func detailsCarrier(_ el: AXUIElement, _ needle: String, depth: Int = 0) -> AXUIElement? {
    if depth > 24 { return nil }
    if (ax(el, kAXRoleAttribute) as? String) == (kAXStaticTextRole as String) {
        let v = ((ax(el, kAXValueAttribute) as? String) ?? "").lowercased()
        let h = ((ax(el, "AXHelp") as? String) ?? "").lowercased()
        if v.contains(needle) || h.contains(needle) { return el }
    }
    for c in children(el) { if let f = detailsCarrier(c, needle, depth: depth + 1) { return f } }
    return nil
}
func detailsText(_ el: AXUIElement) -> String {
    let v = (ax(el, kAXValueAttribute) as? String) ?? ""
    if !v.isEmpty { return v }
    return (ax(el, "AXHelp") as? String) ?? ""
}
func firstLine(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
}
// Item count from the terminal footer line "<size> in <N> items" (fullDetails, ContentView.swift).
func itemsCount(_ text: String) -> Int? {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.count >= 2 else { return nil }
    let l = lines[1]
    guard let r = l.range(of: " items") else { return nil }
    let head = l[..<r.lowerBound]
    guard let sp = head.lastIndex(of: " ") else { return nil }
    let num = head[head.index(after: sp)...].replacingOccurrences(of: ",", with: "")
    return Int(num)
}
// Outline discovery mirrors the reviewed expand mode (AXTable "Folder outline", AXRows).
func outlineTable(_ root: AXUIElement) -> AXUIElement? {
    var queue = children(root), seen = 0
    while !queue.isEmpty && seen < 256 {
        let el = queue.removeFirst(); seen += 1
        if (ax(el, kAXRoleAttribute) as? String) == "AXTable",
           (ax(el, "AXDescription") as? String) == "Folder outline" { return el }
        if (ax(el, kAXRoleAttribute) as? String) != "AXTable" { queue.append(contentsOf: children(el)) }
    }
    return nil
}
func outlineRows(_ t: AXUIElement) -> [AXUIElement] { (ax(t, "AXRows") as? [AXUIElement]) ?? [] }
func rowIdentity(_ row: AXUIElement) -> String {
    if let d = ax(row, "AXDescription") as? String, !d.isEmpty { return d }
    let kids = children(row).compactMap { ax($0, "AXDescription") as? String }.filter { !$0.isEmpty }
    return kids.count == 1 ? kids[0] : ""
}
func chevronIn(_ row: AXUIElement, prefix: String) -> AXUIElement? {
    findRole(row, role: kAXButtonRole as String).first(where: {
        let d = (ax($0, "AXDescription") as? String) ?? (ax($0, kAXTitleAttribute) as? String) ?? ""
        return d.hasPrefix(prefix)
    })
}
// Mid-scan Stop control: same product-true discovery as the reviewed cancel mode (never the
// removal-dialog "Cancel").
func stopButton(_ root: AXUIElement) -> AXUIElement? {
    findRole(root, role: kAXButtonRole as String).first(where: {
        let t = ((ax($0, "AXDescription") as? String) ?? "").lowercased()
        let ti = ((ax($0, kAXTitleAttribute) as? String) ?? "").lowercased()
        return t.contains("stop") || ti.contains("stop")
    })
}
func jsonEsc(_ v: String) -> String {
    var out = ""
    for sc in v.unicodeScalars {
        if sc == "\\" { out += "\\\\" }
        else if sc == "\"" { out += "\\\"" }
        else if sc.value < 0x20 { out += String(format: "\\u%04x", sc.value) }
        else { out.unicodeScalars.append(sc) }
    }
    return out
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[2]) else { print("usage"); exit(2) }
let mode = args[1]
let root = AXUIElementCreateApplication(pid)
guard AXIsProcessTrusted() else { print("ax-trust-denied"); exit(3) }

// Bound every AX IPC call: explicit 3s messaging timeout, process-global (SystemWide) and on the
// app ref. Never rely on a system default (semantics unverified - see header).
guard AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 3.0) == .success else {
    print("messaging-timeout-set-failed scope=system"); exit(5)
}
guard AXUIElementSetMessagingTimeout(root, 3.0) == .success else {
    print("messaging-timeout-set-failed scope=app"); exit(5)
}
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
    // Re-find requires EXACTLY ONE current match: a duplicate AXDescription (two folders with the
    // same name) must never silently attribute a sample to the wrong row - the n-floor does not
    // absorb misattribution, so ambiguity becomes an honest error row instead.
    // JSON string escaping: backslash, quote, and every control char as \u00XX - no silent loss.
    func jesc(_ v: String) -> String {
        var out = ""
        for sc in v.unicodeScalars {
            if sc == "\\" { out += "\\\\" }
            else if sc == "\"" { out += "\\\"" }
            else if sc.value < 0x20 { out += String(format: "\\u%04x", sc.value) }
            else { out.unicodeScalars.append(sc) }
        }
        return out
    }
    func rowByIdentity(_ idn: String) -> AXUIElement? {
        let matches = rowsOf(t).filter { identity($0) == idn }
        return matches.count == 1 ? matches[0] : nil
    }
    // Expandable rows = rows with a visible "Expand" chevron (chevron is hidden for childless rows,
    // OutlineView.swift:288). Pre-registered floor is n>=20 verified samples, so passes adapt to the
    // expandable-row count instead of assuming 12; a true shortfall stays INCONCLUSIVE by the floor.
    var expandable: [(Int, String)] = []
    var seen: [String: Int] = [:]
    for i in 0..<min(rowCount, 24) {
        guard let row = rowsOf(t).dropFirst(i).first, chevron(row, prefix: "Expand") != nil else { continue }
        let idn = identity(row)
        if idn.isEmpty { continue }
        seen[idn, default: 0] += 1
        expandable.append((i, idn))
    }
    // Discovery-time uniqueness filter: duplicate identities are excluded from targets up front
    // (re-find still enforces exactly-one at every poll; virtualization can create new duplicates).
    let ambiguous = Set(expandable.filter { seen[$0.1] ?? 0 > 1 }.map { $0.1 })
    for (i, idn) in expandable where ambiguous.contains(idn) {
        emit(out, "{\"probe\":\"expand\",\"i\":\(i),\"error\":\"identity-ambiguous\",\"id\":\"\(jesc(idn))\"}")
    }
    let targets = Array(expandable.filter { !ambiguous.contains($0.1) }.prefix(12))
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
                emit(out, "{\"probe\":\"expand\",\"pass\":\(pass),\"i\":\(i),\"error\":\"row-identity-unresolved\"}")
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

case "watch":
    let out = args[3]
    let cap = args.count > 4 ? Double(args[4]) ?? 60 : 60
    // Passive scan-window watch: 1 Hz Stop-presence poll, observation only. A wedged app can
    // starve poll iterations (each AX call waits up to the 3s messaging timeout); t_s gaps in
    // the emitted record make that visible, and the in-process watchdog (240s) plus the
    // workflow's external clip bound the total wall-clock.
    let w0 = mach_absolute_time()
    var sawScanning = false
    var settleAt: Double? = nil
    while true {
        let el = ms(w0, mach_absolute_time()) / 1000.0
        if el >= cap { marker("watch-cap-reached cap=\(cap)s"); break }
        let stop = findRole(root, role: kAXButtonRole as String).contains(where: {
            let t = ((ax($0, "AXDescription") as? String) ?? "").lowercased()
            let ti = ((ax($0, kAXTitleAttribute) as? String) ?? "").lowercased()
            return t.contains("stop") || ti.contains("stop")
        })
        if stop { sawScanning = true; settleAt = nil }
        else if sawScanning && settleAt == nil { settleAt = el; marker("watch-scan-window-closed") }
        if let s = settleAt, el - s >= 10 { marker("watch-settle-done"); break }
        emit(out, "{\"probe\":\"diagnostic-watch\",\"t_s\":\(el),\"scanning\":\(stop)}")
        Thread.sleep(forTimeInterval: 1.0)
    }
    print("watch-done")

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

case "cancelrecover":
    let out = args[3]
    guard args.count > 4 else { print("usage: cancelrecover <pid> <out> <fixture> [sentinel] [sentinelChild]"); exit(2) }
    let fixture = args[4]
    let sentinel = args.count > 5 ? args[5] : "spz-readiness-sentinel"
    let sentinelChild = args.count > 6 ? args[6] : "inner"
    // Semantics are declared in the header: ACTIVATION -> CANCELLED STATE -> RECOVERY -> settle.
    let tLaunch = mach_absolute_time()
    // Merged Phase 0+1: Stop discovery polls from t~0 (the AX window's existence is implicit in
    // Stop becoming discoverable, so the separate window wait is folded in). Run 38773486853
    // burned three silent 150s external watchdogs with only stage=start emitted: the per-phase
    // entry marker and bounded AX-walk latency OBS buckets below exist so a starved-AX run is
    // MEASURED, never silent. A "Scanned in" footer before any Stop appears means the scan
    // finished first: fast honest INCONCLUSIVE (~seconds), never a fake press.
    marker("cancelrecover-phase=discovery-enter")
    var stop: AXUIElement?
    var preCompleted = false
    var axCalls = 0
    var axMaxMs = 0.0
    var starvedBuckets = 0
    var bucketStart = mach_absolute_time()
    for _ in 0..<240 {
        let c0 = mach_absolute_time()
        stop = stopButton(root)
        axCalls += 1
        if stop == nil {
            if detailsCarrier(root, "scanned in") != nil { preCompleted = true }
            axCalls += 1
        }
        let c1 = mach_absolute_time()
        let callMs = ms(c0, c1)
        if callMs > axMaxMs { axMaxMs = callMs }
        if ms(bucketStart, c1) >= 5_000 {
            print("OBS cancel-discovery-ax t_s=\(Int(ms(tLaunch, c1) / 1000)) calls=\(axCalls) max-ms=\(axMaxMs)")
            emit(out, "{\"probe\":\"cancelrecover-ax-bucket\",\"calls\":\(axCalls),\"max_ms\":\(axMaxMs)}")
            // Sustained AX ceiling (3 consecutive 5s buckets each riding >= 2500ms on a walk
            // iteration) is measured starvation: bail fast through the INCONCLUSIVE-with-state
            // discipline instead of burning the full external watchdog. Starvation is a
            // hypothesis about the app under 1M scan; this records evidence, not a verdict on it.
            if axMaxMs >= 2_500 { starvedBuckets += 1 } else { starvedBuckets = 0 }
            axCalls = 0; axMaxMs = 0.0; bucketStart = mach_absolute_time()
            if starvedBuckets >= 3 {
                emit(out, "{\"probe\":\"cancelrecover\",\"error\":\"ax-starved\",\"buckets\":\(starvedBuckets)}")
                print("INCONCLUSIVE cancelrecover: ax-starved (3 consecutive 5s buckets with AX-walk max >= 2500ms)"); exit(0)
            }
        }
        if stop != nil || preCompleted { break }
        Thread.sleep(forTimeInterval: 0.25)
    }
    if preCompleted {
        emit(out, "{\"probe\":\"cancelrecover\",\"error\":\"scan-completed-before-press\"}")
        print("INCONCLUSIVE cancelrecover: scan-completed-before-press"); exit(0)
    }
    guard let b = stop else {
        emit(out, "{\"probe\":\"cancelrecover\",\"error\":\"stop-window-never-opened\"}")
        print("INCONCLUSIVE cancelrecover: stop-window-never-opened"); exit(0)
    }
    marker("cancelrecover-stop-found")
    // Locate the footer carrier while the scan is still in flight; if it already finished there
    // is nothing to cancel. preCompleted carries from discovery (always false on entry: the
    // discovery exit fires first) and may still flip here if the scan completes in between.
    var carrier: AXUIElement?
    for _ in 0..<100 {
        if let c = detailsCarrier(root, "scanning:") { carrier = c; break }
        if detailsCarrier(root, "scanned in") != nil { preCompleted = true; break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    if preCompleted {
        emit(out, "{\"probe\":\"cancelrecover\",\"error\":\"scan-completed-before-press\"}")
        print("INCONCLUSIVE cancelrecover: scan-completed-before-press"); exit(0)
    }
    guard carrier != nil else {
        emit(out, "{\"probe\":\"cancelrecover\",\"error\":\"footer-carrier-not-found\"}")
        print("INCONCLUSIVE cancelrecover: footer-carrier-not-found"); exit(0)
    }
    // Phase 2: press + activation evidence (Stop is removed when model.scanning ends). Coarse
    // 300ms walk-based poll: activation is evidence, not the gated latency.
    let tPress = mach_absolute_time()
    AXUIElementPerformAction(b, kAXPressAction as CFString)
    var activated = false
    var tActivated = tPress
    for _ in 0..<50 {
        if stopButton(root) == nil { activated = true; tActivated = mach_absolute_time(); break }
        Thread.sleep(forTimeInterval: 0.3)
    }
    guard activated else {
        emit(out, "{\"probe\":\"cancelrecover\",\"error\":\"activation-not-observed\"}")
        print("INCONCLUSIVE cancelrecover: activation-not-observed"); exit(0)
    }
    emit(out, "{\"probe\":\"cancelrecover-activation\",\"ms\":\(ms(tPress, tActivated))}")
    print("OBS cancel-activation-ms=\(ms(tPress, tActivated))")
    marker("cancelrecover-activated")
    // Phase 3: terminal cancelled/partial state on the cached carrier (cheap 50ms reads; re-walk
    // at most once per second if the ref goes stale). "Scanned in" WITHOUT "Stopped early" means
    // the scan completed naturally: INCONCLUSIVE, never a silent pass.
    var terminalText = ""
    var tTerminal = tPress
    var gotTerminal = false
    var natural = false
    var lastTermState = "none"
    var lastRewalk = tPress
    while ms(tPress, mach_absolute_time()) < 15_000 {
        var text = carrier.map { detailsText($0) } ?? ""
        if text.isEmpty && ms(lastRewalk, mach_absolute_time()) > 1_000 {
            lastRewalk = mach_absolute_time()
            carrier = detailsCarrier(root, "scanning:") ?? detailsCarrier(root, "scanned in")
            text = carrier.map { detailsText($0) } ?? ""
        }
        if !text.isEmpty { lastTermState = text.replacingOccurrences(of: "\n", with: " | ") }
        let low = text.lowercased()
        if low.contains("scanned in") {
            tTerminal = mach_absolute_time()
            if low.contains("stopped early") { terminalText = text; gotTerminal = true } else { natural = true }
            break
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    if natural {
        emit(out, "{\"probe\":\"cancelrecover\",\"error\":\"scan-completed-before-cancel-landed\"}")
        print("INCONCLUSIVE cancelrecover: scan-completed-before-cancel-landed"); exit(0)
    }
    // Stop disappearing proves the press landed and scanning ended; it does NOT prove the
    // footer cancelled state is observable. A missing AX terminal state is INCONCLUSIVE with
    // the last observed state, never a product contradiction.
    guard gotTerminal else {
        emit(out, "{\"probe\":\"cancelrecover\",\"error\":\"missing-terminal-state-15s\",\"last\":\"\(jsonEsc(lastTermState))\"}")
        print("INCONCLUSIVE cancelrecover: missing-terminal-state-15s last=\(lastTermState)"); exit(0)
    }
    let terminalMs = ms(tPress, tTerminal)
    emit(out, "{\"probe\":\"cancelrecover-terminal\",\"ms\":\(terminalMs)}")
    print("OBS cancel-terminal-ms=\(terminalMs)")
    marker("cancelrecover-terminal-cancelled")
    // Tree identity: the cancelled tree's footer root line must still be the fixture path.
    guard firstLine(terminalText) == fixture else {
        emit(out, "{\"probe\":\"cancelrecover\",\"error\":\"wrong-tree-after-cancel\",\"root\":\"\(jsonEsc(firstLine(terminalText)))\"}")
        print("FAIL cancelrecover: wrong-tree-after-cancel root=\(firstLine(terminalText))"); exit(1)
    }
    // Phase 4: follow-up scan via the toolbar Scan menu -> Home Folder (AppModel.scanHome). Menu
    // bridging is not guaranteed by source: any failure here is INCONCLUSIVE, not a product FAIL.
    var scanMenu: AXUIElement?
    for _ in 0..<100 {
        for role in ["AXMenuButton", "AXPopUpButton", kAXButtonRole as String] {
            scanMenu = findRole(root, role: role).first(where: {
                let t = ((ax($0, kAXTitleAttribute) as? String) ?? "").lowercased()
                let d = ((ax($0, "AXDescription") as? String) ?? "").lowercased()
                return t == "scan" || d == "scan"
            })
            if scanMenu != nil { break }
        }
        if scanMenu != nil { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard let menu = scanMenu else {
        emit(out, "{\"probe\":\"cancelrecover\",\"error\":\"scan-menu-not-found\"}")
        print("INCONCLUSIVE cancelrecover: scan-menu-not-found"); exit(0)
    }
    AXUIElementPerformAction(menu, kAXPressAction as CFString)
    var homeItem: AXUIElement?
    for _ in 0..<50 {
        homeItem = findRole(root, role: "AXMenuItem").first(where: {
            ((ax($0, kAXTitleAttribute) as? String) ?? "") == "Home Folder"
        })
        if homeItem != nil { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard let item = homeItem else {
        emit(out, "{\"probe\":\"cancelrecover\",\"error\":\"home-folder-item-not-found\"}")
        print("INCONCLUSIVE cancelrecover: home-folder-item-not-found"); exit(0)
    }
    AXUIElementPerformAction(item, kAXPressAction as CFString)
    marker("cancelrecover-rescan-pressed")
    // Phase 5: the follow-up scan must publish its OWN tree. Acceptance requires ALL of: terminal
    // "Scanned in", no "Stopped early", non-empty root line != fixture. The pre-rescan footer
    // (cancelled fixture tree) fails these by construction, so a stale read can never pass.
    var rescanText = ""
    var rescanOK = false
    var lastRescanState = "none"
    let tR = mach_absolute_time()
    lastRewalk = tR
    while ms(tR, mach_absolute_time()) < 60_000 {
        var text = carrier.map { detailsText($0) } ?? ""
        if text.isEmpty && ms(lastRewalk, mach_absolute_time()) > 1_000 {
            lastRewalk = mach_absolute_time()
            carrier = detailsCarrier(root, "scanning:") ?? detailsCarrier(root, "scanned in")
            text = carrier.map { detailsText($0) } ?? ""
        }
        if !text.isEmpty { lastRescanState = text.replacingOccurrences(of: "\n", with: " | ") }
        let low = text.lowercased()
        if low.contains("scanned in") && !low.contains("stopped early") && !firstLine(text).isEmpty && firstLine(text) != fixture {
            rescanText = text; rescanOK = true; break
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    // Unmet recovery deadline: the runner Home workload is uncontrolled and AX observation can
    // fail, so a missed deadline proves neither stall nor product breakage - INCONCLUSIVE with
    // the last observed footer state as evidence. FAIL stays reserved for contradictory state.
    guard rescanOK else {
        emit(out, "{\"probe\":\"cancelrecover\",\"error\":\"rescan-deadline-not-met-60s\",\"last\":\"\(jsonEsc(lastRescanState))\"}")
        print("INCONCLUSIVE cancelrecover: rescan-deadline-not-met-60s last=\(lastRescanState)"); exit(0)
    }
    let rescanPath = firstLine(rescanText)
    emit(out, "{\"probe\":\"cancelrecover-rescan\",\"root\":\"\(jsonEsc(rescanPath))\",\"ms\":\(ms(tR, mach_absolute_time()))}")
    marker("cancelrecover-rescan-published")
    // Phase 6: known-row evidence on the new tree - the workflow-planted sentinel row must be
    // visible in the outline and expand to its known child.
    var tbl: AXUIElement?
    for _ in 0..<100 {
        tbl = outlineTable(root)
        if tbl != nil { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard let t = tbl else {
        emit(out, "{\"probe\":\"cancelrecover\",\"error\":\"published-outline-missing\"}")
        print("FAIL cancelrecover: published-outline-missing"); exit(1)
    }
    var sentinelRow: AXUIElement?
    for _ in 0..<300 {
        sentinelRow = outlineRows(t).first(where: { rowIdentity($0) == sentinel })
        if sentinelRow != nil { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard let sr = sentinelRow else {
        emit(out, "{\"probe\":\"cancelrecover\",\"error\":\"known-row-missing\",\"row\":\"\(jsonEsc(sentinel))\"}")
        print("FAIL cancelrecover: known-row-missing row=\(sentinel)"); exit(1)
    }
    guard let ch = chevronIn(sr, prefix: "Expand") else {
        emit(out, "{\"probe\":\"cancelrecover\",\"error\":\"known-row-not-expandable\"}")
        print("FAIL cancelrecover: known-row-not-expandable"); exit(1)
    }
    AXUIElementPerformAction(ch, kAXPressAction as CFString)
    var childSeen = false
    for _ in 0..<50 {
        if outlineRows(t).contains(where: { rowIdentity($0) == sentinelChild }) { childSeen = true; break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard childSeen else {
        emit(out, "{\"probe\":\"cancelrecover\",\"error\":\"known-row-expand-unverified\"}")
        print("FAIL cancelrecover: known-row-expand-unverified"); exit(1)
    }
    marker("cancelrecover-known-row-verified")
    // Phase 7: old work must not overwrite the new publication. Three fresh carrier reads over a
    // 6s settle must be byte-identical, keep the rescan root, and stay below fixture magnitude
    // (only the cancelled fixture tree can reach >= 1,000,000 items).
    func freshTerminalText() -> String {
        (detailsCarrier(root, "scanned in") ?? detailsCarrier(root, "scanning:")).map { detailsText($0) } ?? ""
    }
    let s1 = freshTerminalText()
    Thread.sleep(forTimeInterval: 3.0)
    let s2 = freshTerminalText()
    Thread.sleep(forTimeInterval: 3.0)
    let s3 = freshTerminalText()
    guard !s1.isEmpty, s1 == s2, s2 == s3 else {
        emit(out, "{\"probe\":\"cancelrecover\",\"error\":\"publication-unstable-or-overwritten\"}")
        print("FAIL cancelrecover: publication-unstable-or-overwritten"); exit(1)
    }
    guard firstLine(s3) == rescanPath else {
        emit(out, "{\"probe\":\"cancelrecover\",\"error\":\"old-work-path-flip\",\"root\":\"\(jsonEsc(firstLine(s3)))\"}")
        print("FAIL cancelrecover: old-work-path-flip root=\(firstLine(s3))"); exit(1)
    }
    guard let rescanItems = itemsCount(s3) else {
        emit(out, "{\"probe\":\"cancelrecover\",\"error\":\"rescan-footer-unparsed\"}")
        print("INCONCLUSIVE cancelrecover: rescan-footer-unparsed"); exit(0)
    }
    guard rescanItems < 1_000_000 else {
        emit(out, "{\"probe\":\"cancelrecover\",\"error\":\"old-work-magnitude\",\"items\":\(rescanItems)}")
        print("FAIL cancelrecover: old-work-magnitude items=\(rescanItems)"); exit(1)
    }
    emit(out, "{\"probe\":\"cancelrecover\",\"result\":\"pass\",\"terminal_ms\":\(terminalMs),\"rescan_items\":\(rescanItems)}")
    print("PASS cancelrecover: terminal=\(terminalMs)ms rescan=\(rescanPath) items=\(rescanItems) knownrow=\(sentinel) settle=stable")
    print("cancelrecover-done")

case "publish1m":
    let out = args[3]
    let expectTop = args.count > 4 ? Int(args[4]) ?? 200 : 200
    let expectItems = args.count > 5 ? Int(args[5]) ?? 1_000_400 : 1_000_400
    let firstRow = args.count > 6 ? args[6] : "d000"
    let lastRow = args.count > 7 ? args[7] : "d199"
    let expandRow = args.count > 8 ? args[8] : "d150"
    let expectChildren = args.count > 9 ? Int(args[9]) ?? 5001 : 5001
    // Semantics are declared in the header: attach->published interval, all-required visible
    // state, 30s must-terminate ceiling (not a performance bar), observational samples only.
    // Window wait folded into the publication wait: polling starts at t0 (attach), and each
    // second's AX-walk latency is itself the starvation OBS sample (printed AND jsonl). Run
    // 38773486853 left the starvation hypothesis unmeasured; these samples measure it.
    let t0 = mach_absolute_time()
    var hasWindow = false
    var carrier: AXUIElement?
    var published = false
    var pubText = ""
    var lastState = "none"
    var sampleI = 0
    marker("publish1m-phase=publication-wait-enter")
    while ms(t0, mach_absolute_time()) < 30_000 {
        sampleI += 1
        let s0 = mach_absolute_time()
        if !hasWindow {
            let wins = ax(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
            if !wins.isEmpty { hasWindow = true; marker("publish1m-window-found") }
        } else {
            if carrier == nil { carrier = detailsCarrier(root, "scanning:") ?? detailsCarrier(root, "scanned in") }
            if let c = carrier {
                let text = detailsText(c)
                if text.isEmpty {
                    carrier = nil
                } else {
                    lastState = text.replacingOccurrences(of: "\n", with: " | ")
                    let low = text.lowercased()
                    if low.contains("scanned in") && !low.contains("scanning:") {
                        published = true; pubText = text
                    }
                }
            }
        }
        let s1 = mach_absolute_time()
        emit(out, "{\"probe\":\"publish1m-ax-sample\",\"i\":\(sampleI),\"ms\":\(ms(s0, s1))}")
        print("OBS publish-ax-sample-ms i=\(sampleI) ms=\(ms(s0, s1))")
        if published { break }
        Thread.sleep(forTimeInterval: 1.0)
    }
    guard hasWindow else {
        emit(out, "{\"probe\":\"publish1m\",\"error\":\"no-ax-window-30s\"}")
        print("INCONCLUSIVE publish1m: no-ax-window-30s"); exit(0)
    }
    // Unmet engineering smoke deadline: a still-"Scanning:" (or unreadable) footer at 30s does
    // not prove a product stall - workload and AX observation are uncontrolled. INCONCLUSIVE
    // with the last observed state; FAIL stays reserved for contradictory state/count/tree.
    guard published else {
        emit(out, "{\"probe\":\"publish1m\",\"error\":\"deadline-not-met-30s\",\"last\":\"\(jsonEsc(lastState))\"}")
        print("INCONCLUSIVE publish1m: deadline-not-met-30s last=\(lastState)"); exit(0)
    }
    let pubMs = ms(t0, mach_absolute_time())
    emit(out, "{\"probe\":\"publish1m\",\"attach_to_published_ms\":\(pubMs)}")
    print("OBS publish-attach-to-published-ms=\(pubMs)")
    marker("publish1m-terminal-published")
    // Visible success state: not partial, exact item count, exact top-level rows, known rows.
    guard !pubText.lowercased().contains("stopped early") else {
        emit(out, "{\"probe\":\"publish1m\",\"error\":\"published-partial-unexpectedly\"}")
        print("FAIL publish1m: published-partial-unexpectedly"); exit(1)
    }
    guard let items = itemsCount(pubText) else {
        emit(out, "{\"probe\":\"publish1m\",\"error\":\"published-footer-unparsed\"}")
        print("INCONCLUSIVE publish1m: published-footer-unparsed"); exit(0)
    }
    guard items == expectItems else {
        emit(out, "{\"probe\":\"publish1m\",\"error\":\"published-item-count-mismatch\",\"got\":\(items),\"want\":\(expectItems)}")
        print("FAIL publish1m: published-item-count-mismatch got=\(items) want=\(expectItems)"); exit(1)
    }
    guard let t = outlineTable(root) else {
        emit(out, "{\"probe\":\"publish1m\",\"error\":\"published-outline-missing\"}")
        print("FAIL publish1m: published-outline-missing"); exit(1)
    }
    let rows = outlineRows(t)
    guard rows.count == expectTop else {
        emit(out, "{\"probe\":\"publish1m\",\"error\":\"published-row-count-mismatch\",\"got\":\(rows.count),\"want\":\(expectTop)}")
        print("FAIL publish1m: published-row-count-mismatch got=\(rows.count) want=\(expectTop)"); exit(1)
    }
    let ids = Set(rows.map { rowIdentity($0) })
    guard ids.contains(firstRow), ids.contains(lastRow) else {
        emit(out, "{\"probe\":\"publish1m\",\"error\":\"published-known-rows-missing\"}")
        print("FAIL publish1m: published-known-rows-missing"); exit(1)
    }
    marker("publish1m-visible-state-verified")
    // Observation only (never gated, not the pre-registered expansion target): one chevron
    // expansion on the published tree, verified by row-count growth to expectTop+expectChildren.
    var expandResult = "row-or-chevron-not-found"
    if let row0 = rows.first(where: { rowIdentity($0) == expandRow }), let ec = chevronIn(row0, prefix: "Expand") {
        let e0 = mach_absolute_time()
        AXUIElementPerformAction(ec, kAXPressAction as CFString)
        var grew = false
        var e1 = e0
        for _ in 0..<50 {
            if outlineRows(t).count == expectTop + expectChildren { grew = true; e1 = mach_absolute_time(); break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if grew {
            expandResult = "verified"
            emit(out, "{\"probe\":\"publish1m-expand-check\",\"ms\":\(ms(e0, e1))}")
            print("OBS publish-expand-ms=\(ms(e0, e1))")
        } else {
            expandResult = "unverified-5s"
        }
    }
    emit(out, "{\"probe\":\"publish1m-expand-check\",\"result\":\"\(jsonEsc(expandResult))\"}")
    print("OBS publish-expand-check=\(expandResult)")
    emit(out, "{\"probe\":\"publish1m\",\"result\":\"pass\",\"attach_to_published_ms\":\(pubMs),\"items\":\(items),\"rows\":\(rows.count)}")
    print("PASS publish1m: scan-footer-and-toprows-published attach-to-published=\(pubMs)ms rows=\(rows.count) items=\(items)")
    print("publish1m-done")

default:
    print("unknown mode"); exit(2)
}
