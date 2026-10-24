import Foundation
import ApplicationServices
import Darwin

// Read-only external observation. No trust prompts, actions, label substitution or
// gate integration. Binding fields are caller-supplied anchors, not proof by themselves.
struct SheetProbeResult: Codable {
    var source = "external-AXUIElement"
    var pid: Int32
    var step: Int
    var captureToken: String
    var identity = "unknown"
    var rows = 0
    var complete = false
    var reason = "not inspected"
    var scopeCount = 0
    var texts: [String] = []
}
func probeSheet(pid: Int32, step: Int, token: String) -> SheetProbeResult {
    var result = SheetProbeResult(pid: pid, step: step, captureToken: token)
    guard pid > 0, step > 0, !token.isEmpty else { result.reason = "invalid anchor"; return result }
    guard AXIsProcessTrusted() else { result.reason = "AX trust unavailable"; return result }
    let app = AXUIElementCreateApplication(pid)
    var error = ""
    func read(_ node: AXUIElement, _ key: String, optional: Bool = false) -> CFTypeRef? {
        var value: CFTypeRef?
        let rc = AXUIElementCopyAttributeValue(node, key as CFString, &value)
        if rc == .success { return value }
        if optional && (rc == .attributeUnsupported || rc == .noValue) { return nil }
        error = "attribute \(key) error \(rc.rawValue)"; return nil
    }
    func text(_ node: AXUIElement, _ key: String, optional: Bool = false) -> String? {
        guard let value = read(node, key, optional: optional) else { return nil }
        guard let string = value as? String else {
            // Numeric AXValue is normal for buttons/selection controls. It carries
            // no observed identity text; other malformed text attributes refuse.
            if key != "AXValue" { error = "non-string \(key)" }
            return nil
        }
        return string
    }
    func array(_ node: AXUIElement, _ key: String, optional: Bool = false) -> [AXUIElement] {
        guard let value = read(node, key, optional: optional) else { return [] }
        guard let array = value as? [AXUIElement] else { error = "non-array \(key)"; return [] }
        return array
    }
    let windows = array(app, "AXWindows")
    guard error.isEmpty, !windows.isEmpty else { result.reason = error.isEmpty ? "no windows" : error; return result }
    // Every visited node has the same verified process; parent indexes retain
    // actual topology without asking AXParent to guess or select another window.
    var nodes: [(element: AXUIElement, parent: Int?, depth: Int, role: String, texts: [String])] = []
    var pending = windows.map { ($0, Optional<Int>.none, 0, [AXUIElement]()) }
    var edges: [Int: Set<Int>] = [:]
    var qi = 0
    while qi < pending.count {
        guard nodes.count < 2048 else { error = "node cap"; break }
        let (node, parent, depth, ancestors) = pending[qi]; qi += 1
        guard depth < 32 else { error = "depth cap"; break }
        if ancestors.contains(where: { CFEqual($0, node) }) { error = "cyclic graph"; break }
        if let existing = nodes.firstIndex(where: { CFEqual($0.element, node) }) {
            if let parent { edges[parent, default: []].insert(existing) }
            continue // Shared AX child in a DAG, not a cycle or second panel.
        }
        var actualPID: pid_t = 0
        let pidError = AXUIElementGetPid(node, &actualPID)
        guard pidError == .success, actualPID == pid else { error = "node PID mismatch or unreadable"; break }
        guard let role = text(node, "AXRole"), !role.isEmpty else { if error.isEmpty { error = "missing role" }; break }
        let texts = ["AXTitle", "AXDescription", "AXValue", "AXLabel"].compactMap { text(node, $0, optional: true) }.filter { !$0.isEmpty }
        guard error.isEmpty else { break }
        let index = nodes.count
        nodes.append((node, parent, depth, role, texts))
        if let parent { edges[parent, default: []].insert(index) }
        // AXSheets is a separate public relationship and need not be repeated in
        // AXChildren. Both routes belong to the same verified app/window graph.
        let children = array(node, "AXChildren", optional: true) + array(node, "AXSheets", optional: true)
        guard error.isEmpty else { break }
        pending += children.map { ($0, Optional(index), depth + 1, ancestors + [node]) }
    }
    guard error.isEmpty else { result.reason = error; return result }
    func below(_ index: Int, _ ancestor: Int) -> Bool {
        var pending = [ancestor], seen = Set<Int>()
        while let i = pending.popLast() {
            if i == index { return true }
            if seen.insert(i).inserted { pending += edges[i, default: []] }
        }
        return false
    }
    // Only sheet/dialog/popover scopes exported by THIS process count. Collapse
    // nested representations of one panel; disjoint independent scopes refuse.
    let scopes = nodes.indices.filter { i in
        let node = nodes[i]
        if node.role == "AXSheet" || node.role == "AXPopover" { return true }
        if node.role == "AXWindow" {
            return ["AXSystemDialog", "AXDialog"].contains(text(node.element, "AXSubrole", optional: true) ?? "")
        }
        return false
    }
    guard error.isEmpty else { result.reason = error; return result }
    let collapsed = scopes.filter { a in !scopes.contains { b in a != b && below(b, a) } }
    result.scopeCount = collapsed.count
    guard collapsed.count == 1 else { result.reason = "expected one independent foreground panel"; return result }
    let scope = collapsed[0]
    // An exported stale/background panel is not the captured foreground panel.
    guard let focusedRef = read(app, "AXFocusedWindow") else { result.reason = error; return result }
    guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { result.reason = "focused window has wrong AX type"; return result }
    let focused = focusedRef as! AXUIElement // checked CF type, not an unchecked cast
    guard let focusedIndex = nodes.firstIndex(where: { CFEqual($0.element, focused) }),
          below(scope, focusedIndex) || below(focusedIndex, scope) else {
        result.reason = "panel not related to focused window"; return result
    }
    let content = nodes.indices.filter { below($0, scope) }
    result.texts = content.flatMap { nodes[$0].texts }
    result.rows = content.filter { nodes[$0].role == "AXRow" }.count
    // Exact observed content, never a fixture expectation or presentation intent.
    let notScannedTitle = result.texts.contains("Not scanned")
    let notScanned = notScannedTitle && result.texts.contains("These locations were not scanned, so they are not in the totals.")
    let removalResult = result.texts.contains { $0.hasPrefix("Moved ") && $0.contains("to the Trash.") }
    guard notScanned != removalResult, !(notScannedTitle && removalResult) else { result.reason = "unknown or conflicting panel identity"; return result }
    if notScanned {
        guard nodes[scope].role == "AXSheet", result.rows > 0 else { result.reason = "not a loaded sheet"; return result }
        result.identity = "notscanned"
    } else { result.identity = "removal-result" }
    result.complete = true
    result.reason = "observed"
    return result
}

let args = CommandLine.arguments
if args.count != 4 { fputs("usage: sheet-probe PID STEP CAPTURE_TOKEN\n", stderr); exit(2) }
let result = probeSheet(pid: Int32(args[1]) ?? 0, step: Int(args[2]) ?? 0, token: args[3])
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) { print(json) }
else { exit(2) }
exit(result.complete ? 0 : 1)
