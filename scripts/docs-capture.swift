import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

// Docs capture helper (CI, informational). Drives the real app on a disposable fixture through ordinary
// accessibility presses and keystrokes, and prints the window id for `screencapture -l`.
//   docs-capture <pid> windowid          largest on-screen window of the process
//   docs-capture <pid> press <label>     AXPress the control whose title/description/value is <label>
//   docs-capture <pid> type <text>       focus "Filter by name" and type <text>
//   docs-capture <pid> select <index>    select the row at <index> of the first table
//   docs-capture <pid> escape            press Escape
//   docs-capture <pid> rect              "x,y,w,h" union of all on-screen windows of the process (main window, sheets, popovers) for screencapture -R
//   docs-capture <pid> choose <menu button label> <item title>   open a toolbar menu and press one of its items (diagnostics via dump)
//   docs-capture <pid> frame <label>     "x,y,w,h" (screen points) of the element whose title/description/value/label is <label>
//   docs-capture <pid> dump              print role|title|description|label of the accessibility tree (diagnostic only)
//   docs-capture <pid> hastext <text>    exit 0 only if <text> appears in some element's title/description/value/label
//   docs-capture <pid> sheettext <text>  exit 0 only if <text> appears inside a dialog/sheet/popover's own subtree (never background chrome)
// Exit 1 when a control is not found. Never touches the Trash or any real file.
let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[1]) else { FileHandle.standardError.write(Data("usage\n".utf8)); exit(2) }
let command = args[2]
let app = AXUIElementCreateApplication(pid)

func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}
func string(_ element: AXUIElement, _ name: String) -> String { read(element, name) as? String ?? "" }
func descendants(limit: Int = 4096) -> [AXUIElement] {
    var queue = [AXUIElement](), seen = [AXUIElement](), i = 0
    if let windows = read(app, "AXWindows") as? [AXUIElement] { queue += windows }
    while i < queue.count && seen.count < limit {
        let element = queue[i]; i += 1
        seen.append(element)
        let role = string(element, "AXRole")
        if role == "AXTable" || role == "AXOutline" { continue }   // do not enumerate thousands of rows
        if let children = read(element, "AXChildren") as? [AXUIElement] { queue += children }
    }
    return seen
}
func label(_ element: AXUIElement, matches text: String) -> Bool {
    // SwiftUI .accessibilityLabel can surface as AXTitle or AXLabel depending on control and OS version; match both.
    string(element, "AXTitle") == text || string(element, "AXDescription") == text || string(element, "AXValue") == text || string(element, "AXLabel") == text
}
func post(key: CGKeyCode) {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
    down?.post(tap: .cghidEventTap); usleep(40_000); up?.post(tap: .cghidEventTap)
}
func post(character: Character) {
    let units = Array(String(character).utf16)
    let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
    down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
    up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
    down?.post(tap: .cghidEventTap); usleep(30_000); up?.post(tap: .cghidEventTap); usleep(30_000)
}

switch command {
case "windowid":
    let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    var best: (id: Int, area: Double)? = nil
    for w in info where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
        guard let id = w[kCGWindowNumber as String] as? Int, let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
        let area = (b["Width"] ?? 0) * (b["Height"] ?? 0)
        if best == nil || area > best!.area { best = (id, area) }
    }
    guard let b = best else { print("no window"); exit(1) }
    print(b.id)
case "press":
    guard args.count == 4 else { exit(2) }
    let pressable: Set<String> = ["AXRadioButton", "AXButton", "AXTab", "AXMenuButton", "AXPopUpButton", "AXCheckBox"]
    guard let target = descendants().first(where: { pressable.contains(string($0, "AXRole")) && label($0, matches: args[3]) }) else { print("not found: \(args[3])"); exit(1) }
    // AXPress on a control of a non-active app can fail; bring the app forward first (same as `escape`).
    NSRunningApplication(processIdentifier: pid)?.activate()
    usleep(200_000)
    guard AXUIElementPerformAction(target, "AXPress" as CFString) == .success else { print("press failed: \(args[3])"); exit(1) }
case "type":
    guard args.count == 4 else { exit(2) }
    guard let field = descendants().first(where: { string($0, "AXRole") == "AXTextField" && string($0, "AXDescription") == "Filter by name" }) else { print("no filter field"); exit(1) }
    _ = AXUIElementSetAttributeValue(field, "AXFocused" as CFString, kCFBooleanTrue)
    NSRunningApplication(processIdentifier: pid)?.activate()
    usleep(400_000)
    for character in args[3] { post(character: character) }
case "select":
    guard args.count == 4, let index = Int(args[3]) else { exit(2) }
    guard let table = descendants().first(where: { string($0, "AXRole") == "AXTable" || string($0, "AXRole") == "AXOutline" }),
          let rows = read(table, "AXRows") as? [AXUIElement], index < rows.count else { print("no row \(args[3])"); exit(1) }
    guard AXUIElementSetAttributeValue(rows[index], "AXSelected" as CFString, kCFBooleanTrue) == .success else { print("select failed"); exit(1) }
case "rect":
    let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude, maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
    var found = false
    for w in info where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
        guard let b = w[kCGWindowBounds as String] as? [String: Double], let width = b["Width"], let height = b["Height"],
              width >= 50, height >= 50, (w[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
        let x = b["X"] ?? 0, y = b["Y"] ?? 0
        minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x + width); maxY = max(maxY, y + height); found = true
    }
    guard found else { print("no window"); exit(1) }
    print("\(Int(minX)),\(Int(minY)),\(Int(maxX - minX)),\(Int(maxY - minY))")
case "selectrow":
    // Select the first row (in any table/outline) whose visible text contains args[3]. v1-capture uses this to target
    // ONE specific fixture FILE: "row 0 of the first table" is the outline's largest FOLDER (run 39947043378 trashed
    // the whole Archives folder instead of one file).
    guard args.count == 4 else { exit(2) }
    func rowText(_ row: AXUIElement, _ depth: Int = 0) -> String {
        guard depth < 3 else { return "" }
        var text = string(row, "AXTitle") + " " + string(row, "AXValue") + " " + string(row, "AXLabel") + " " + string(row, "AXDescription")
        for child in (read(row, "AXChildren") as? [AXUIElement]) ?? [] { text += " " + rowText(child, depth + 1) }
        return text
    }
    var target: AXUIElement? = nil
    for el in descendants(limit: 8192) where ["AXTable", "AXOutline"].contains(string(el, "AXRole")) {
        for row in (read(el, "AXRows") as? [AXUIElement]) ?? [] where rowText(row).contains(args[3]) { target = row; break }
        if target != nil { break }
    }
    guard let row = target else { print("row not found: \(args[3])"); exit(1) }
    guard AXUIElementSetAttributeValue(row, "AXSelected" as CFString, kCFBooleanTrue) == .success else { print("select failed: \(args[3])"); exit(1) }
case "choose":
    guard args.count == 5 else { exit(2) }
    let openers: Set<String> = ["AXMenuButton", "AXPopUpButton", "AXButton"]
    NSRunningApplication(processIdentifier: pid)?.activate()
    usleep(200_000)
    guard let opener = descendants().first(where: { openers.contains(string($0, "AXRole")) && label($0, matches: args[3]) }) else { print("menu button not found: \(args[3])"); exit(1) }
    let openError = AXUIElementPerformAction(opener, "AXPress" as CFString)
    print("choose opener role=\(string(opener, "AXRole")) title=\(string(opener, "AXTitle")) description=\(string(opener, "AXDescription")) value=\(string(opener, "AXValue")) pressError=\(openError.rawValue)")
    guard openError == .success else { print("menu press failed: \(args[3])"); exit(1) }
    usleep(800_000)
    guard let item = descendants(limit: 8192).first(where: { string($0, "AXRole") == "AXMenuItem" && string($0, "AXTitle") == args[4] }) else {
        print("menu item not found: \(args[4])"); post(key: 53); exit(1)
    }
    let itemError = AXUIElementPerformAction(item, "AXPress" as CFString)
    print("choose item role=\(string(item, "AXRole")) title=\(string(item, "AXTitle")) description=\(string(item, "AXDescription")) value=\(string(item, "AXValue")) pressError=\(itemError.rawValue)")
    guard itemError == .success else { print("menu item press failed: \(args[4])"); exit(1) }
case "frame":
    guard args.count == 4 else { exit(2) }
    guard let el = descendants().first(where: { label($0, matches: args[3]) }),
          let posRef = read(el, "AXPosition"), let sizeRef = read(el, "AXSize") else { print("no frame: \(args[3])"); exit(1) }
    var pt = CGPoint.zero, sz = CGSize.zero
    guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pt), AXValueGetValue(sizeRef as! AXValue, .cgSize, &sz) else { print("bad frame: \(args[3])"); exit(1) }
    print("\(Int(pt.x)),\(Int(pt.y)),\(Int(sz.width)),\(Int(sz.height))")
case "dump":
    for element in descendants(limit: 1500).prefix(400) {
        print("\(string(element, "AXRole"))|\(string(element, "AXTitle"))|\(string(element, "AXDescription"))|\(string(element, "AXLabel"))")
    }
case "hastext":
    guard args.count == 4 else { exit(2) }
    let needle = args[3]
    let hit = descendants().contains { element in
        string(element, "AXTitle").contains(needle) || string(element, "AXDescription").contains(needle) ||
        string(element, "AXValue").contains(needle) || string(element, "AXLabel").contains(needle)
    }
    if !hit { print("text not present: \(needle)"); exit(1) }
case "nosheet":
    // An inaccessible tree is not proof of absence. Read the actual application's
    // windows successfully, then refuse any live sheet/dialog/popover in their subtree.
    guard let windows = read(app, "AXWindows") as? [AXUIElement], !windows.isEmpty else { print("windows unavailable"); exit(1) }
    var queue = windows, i = 0
    while i < queue.count {
        guard i < 8192 else { print("tree truncated"); exit(1) }
        let el = queue[i]; i += 1
        guard let role = read(el, "AXRole") as? String else { print("role unavailable"); exit(1) }
        if role == "AXSheet" || role == "AXPopover" || (role == "AXWindow" && ["AXSystemDialog", "AXDialog"].contains(string(el, "AXSubrole"))) { print("foreground panel still present"); exit(1) }
        // Enumerating result-table rows is unnecessary and can exhaust the bound.
        // Still require a readable role for every visited node. An AX error other
        // than unsupported/no-value is not evidence that a subtree is absent.
        if role == "AXTable" || role == "AXOutline" { continue }
        var childrenRef: CFTypeRef?
        let rc = AXUIElementCopyAttributeValue(el, "AXChildren" as CFString, &childrenRef)
        if rc == .success {
            guard let children = childrenRef as? [AXUIElement] else { print("invalid children"); exit(1) }
            queue += children
        } else if rc != .attributeUnsupported && rc != .noValue {
            print("children unavailable"); exit(1)
        }
    }
    print("no foreground panel")
case "sheettext":
    // Text must appear in a FOREGROUND dialog/sheet/popover's OWN subtree, never in background window chrome:
    // a confirmation or result must be scoped by the dialog's own text - a background element carrying the same
    // string (e.g. the Largest row behind the dialog, whose full path matches the guard's expected path) must NOT
    // satisfy a dialog-scope check (reviewer challenge on 0d8ed84; run 39947043378's dialog named the Archives
    // FOLDER while the file row sat behind it).
    guard args.count == 4 else { exit(2) }
    let needle = args[3]
    var scopes: [AXUIElement] = []
    for el in descendants(limit: 8192) {
        let role = string(el, "AXRole")
        if role == "AXSheet" || role == "AXPopover" || (role == "AXWindow" && ["AXSystemDialog", "AXDialog"].contains(string(el, "AXSubrole"))) { scopes.append(el) }
    }
    func textIn(_ root: AXUIElement) -> Bool {
        var queue = [root], i = 0, seen = 0
        while i < queue.count && seen < 2048 {
            let el = queue[i]; i += 1; seen += 1
            if string(el, "AXTitle").contains(needle) || string(el, "AXDescription").contains(needle) ||
               string(el, "AXValue").contains(needle) || string(el, "AXLabel").contains(needle) { return true }
            if let children = read(el, "AXChildren") as? [AXUIElement] { queue += children }
        }
        return false
    }
    // One VISUAL panel can surface as nested AX matches (e.g. an AXSystemDialog window containing an AXSheet child):
    // collapse ancestors whose subtree contains another collected scope, keeping the innermost panel, so one panel
    // counts once. Exactly ONE INDEPENDENT foreground scope is then required: two disjoint panels, or a stale
    // background dialog beside the real one, refuse - a background surface cannot launder an end state (reviewer).
    // The capture script escapes each surface before opening the next, so a healthy flow shows exactly one panel;
    // transient overlaps are retried by the caller's bounded poll.
    func ancestors(of el: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = [], cur = el, seen = Set<UInt>()
        for _ in 0..<64 {   // bounded: parent chains are short; the visited set breaks any attribute cycle
            // AXParent of an AX element is always an AX element; conditional downcast to a CF type is a compile
            // ERROR on the real toolchain ("will always succeed" - run 39961036509 step-8 log), so force-cast like
            // the posRef as! AXValue precedent in `frame` above.
            guard let parentRef = read(cur, "AXParent") else { break }
            let parent = parentRef as! AXUIElement
            if !seen.insert(CFHash(parent)).inserted { break }
            out.append(parent); cur = parent
        }
        return out
    }
    let collapsed = scopes.filter { a in !scopes.contains { b in !CFEqual(b, a) && ancestors(of: b).contains(where: { CFEqual($0, a) }) } }
    guard collapsed.count == 1 else { print("expected exactly one independent dialog/sheet/popover scope, found \(collapsed.count) (of \(scopes.count) matches)"); exit(1) }
    guard textIn(collapsed[0]) else { print("text not in the foreground dialog/sheet/popover: \(needle)"); exit(1) }
case "snapshot":
    // Read-only LIVE-state evidence (the "maximum leverage from a Mac contact" requirement): bounded full
    // attribute/type/selected state WHILE a surface is presented, so one run settles the SDK/AX unknowns
    // (scope identity, AXSelected write semantics, parent chains) whether the flow passes or fails. The capture
    // script calls this before AND after mutating actions and on every failure path (diag).
    print("== windows (CGWindowList, on-screen, this pid) ==")
    if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
        for w in info where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
            print("window id=\(w[kCGWindowNumber as String] ?? "?") layer=\(w[kCGWindowLayer as String] ?? "?") alpha=\(w[kCGWindowAlpha as String] ?? "?") bounds=\(w[kCGWindowBounds as String] ?? [:])")
        }
    }
    // Dedicated bounded walk: unlike descendants() this does NOT skip table/outline children - the selected ROW
    // (the mutating action's target) lives inside the outline - but stays capped (512 elements, depth 24).
    var queue: [(AXUIElement, Int)] = [], qi = 0
    if let windows = read(app, "AXWindows") as? [AXUIElement] { queue += windows.map { ($0, 0) } }
    var els: [(AXUIElement, Int)] = []
    while qi < queue.count && els.count < 512 {
        let (el, d) = queue[qi]; qi += 1; els.append((el, d))
        if d < 24, let children = read(el, "AXChildren") as? [AXUIElement] { queue += children.map { ($0, d + 1) } }
    }
    print("== tree (first \(els.count) elements, caps 512/depth 24) ==")
    var selected: [(Int, AXUIElement)] = []
    for (idx, pair) in els.enumerated() {
        let (el, d) = pair
        let sel = read(el, "AXSelected").map { CFEqual($0, kCFBooleanTrue) } ?? false
        let foc = read(el, "AXFocused").map { CFEqual($0, kCFBooleanTrue) } ?? false
        var pt = CGPoint.zero, sz = CGSize.zero, frame = "-"
        if let posRef = read(el, "AXPosition"), let sizeRef = read(el, "AXSize"),
           AXValueGetValue(posRef as! AXValue, .cgPoint, &pt), AXValueGetValue(sizeRef as! AXValue, .cgSize, &sz) {
            frame = "\(Int(pt.x)),\(Int(pt.y)),\(Int(sz.width)),\(Int(sz.height))"
        }
        print("#\(idx) depth=\(d) role=\(string(el, "AXRole")) subrole=\(string(el, "AXSubrole")) selected=\(sel) focused=\(foc) frame=\(frame) title=\(string(el, "AXTitle").prefix(80)) desc=\(string(el, "AXDescription").prefix(80)) label=\(string(el, "AXLabel").prefix(80)) value=\(string(el, "AXValue").prefix(120))")
        if sel { selected.append((idx, el)) }
    }
    print("== foreground scopes (sheettext predicate over the visited cap; the live collapse verdict) ==")
    var scopeCount = 0
    for (el, _) in els {
        let role = string(el, "AXRole")
        if role == "AXSheet" || role == "AXPopover" || (role == "AXWindow" && ["AXSystemDialog", "AXDialog"].contains(string(el, "AXSubrole"))) {
            scopeCount += 1
            print("scope #\(scopeCount) role=\(role) subrole=\(string(el, "AXSubrole")) title=\(string(el, "AXTitle").prefix(80))")
        }
    }
    print("scopes=\(scopeCount)")
    print("== selected targets (parent role chains, innermost first) ==")
    for (idx, el) in selected {
        var chain: [String] = [], cur = el
        for _ in 0..<16 {   // bounded; parent chains are short
            guard let parentRef = read(cur, "AXParent") else { break }
            let parent = parentRef as! AXUIElement   // same proven idiom as ancestors() above (run 39961036509)
            chain.append(string(parent, "AXRole")); cur = parent
        }
        print("selected #\(idx) chain=\(chain.joined(separator: " < "))")
    }
case "escape":
    NSRunningApplication(processIdentifier: pid)?.activate()
    usleep(300_000)
    post(key: 53)
default:
    exit(2)
}
