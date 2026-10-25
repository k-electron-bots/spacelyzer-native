import Foundation
import ApplicationServices
import CoreGraphics
import Darwin
setbuf(stdout, nil)
// Accessibility and key-event driver for the ship-candidate run. External process, never prompts for trust.
// Usage: ship-ui trust | tree <pid> | press <pid> <role> <needle> | set <pid> <role> <needle> <value> | focus <pid> | key|keytap <pid> <keycode> [cmd|shift|opt|ctrl]...
// Output is one JSON object per line on stdout so a Python judge can parse it. Exit 0 = the call ran; the judge decides pass/fail.
func emit(_ o: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), let s = String(data: d, encoding: .utf8) { print(s) }
}
func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    let r = AXUIElementCopyAttributeValue(e, name as CFString, &v)
    return r == .success ? v : nil
}
func str(_ e: AXUIElement, _ name: String) -> String { (attr(e, name) as? String) ?? "" }
func describe(_ e: AXUIElement, depth: Int, path: String) -> [String: Any] {
    var enabled = true
    if let b = attr(e, kAXEnabledAttribute as String) as? Bool { enabled = b }
    var focused = false
    if let b = attr(e, kAXFocusedAttribute as String) as? Bool { focused = b }
    var value = ""
    if let s = attr(e, kAXValueAttribute as String) as? String { value = s }
    return ["depth": depth, "path": path, "role": str(e, kAXRoleAttribute as String), "subrole": str(e, kAXSubroleAttribute as String),
            "title": str(e, kAXTitleAttribute as String), "desc": str(e, kAXDescriptionAttribute as String),
            "id": str(e, kAXIdentifierAttribute as String), "value": value, "enabled": enabled, "focused": focused]
}
/// Depth-first walk with hard bounds so a pathological tree cannot hang the run.
func walk(_ root: AXUIElement, limit: Int = 800, _ visit: (AXUIElement, [String: Any]) -> Bool) {
    var count = 0
    func go(_ e: AXUIElement, _ depth: Int, _ path: String) -> Bool {
        guard depth <= 24, count < limit else { return true }
        count += 1
        let d = describe(e, depth: depth, path: path)
        if !visit(e, d) { return false }
        let kids = (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
        for (i, k) in kids.enumerated() { if !go(k, depth + 1, path + "/" + String(i)) { return false } }
        return true
    }
    _ = go(root, 0, "")
}
func matches(_ d: [String: Any], role: String, needle: String) -> Bool {
    guard (d["role"] as? String) == role else { return false }
    if needle.isEmpty { return true }
    // A leading "=" asks for an exact field match, so "=Largest" cannot hit "Export the Largest list as CSV".
    let exact = needle.hasPrefix("=")
    let want = exact ? String(needle.dropFirst()) : needle
    for k in ["title", "desc", "id", "value"] { if let s = d[k] as? String, !s.isEmpty, exact ? s == want : s.contains(want) { return true } }
    return false
}
let args = CommandLine.arguments
guard args.count >= 2 else { emit(["error": "usage"]); exit(2) }
let cmd = args[1]
if cmd == "trust" { emit(["cmd": "trust", "trusted": AXIsProcessTrusted()]); exit(0) }
guard args.count >= 3, let pidv = Int32(args[2]), pidv > 0 else { emit(["error": "pid"]); exit(2) }
let pid = pid_t(pidv)
guard AXIsProcessTrusted() else { emit(["cmd": cmd, "error": "not-trusted"]); exit(3) }
let app = AXUIElementCreateApplication(pid)
switch cmd {
case "tree":
    var n = 0
    walk(app) { _, d in emit(d); n += 1; return true }
    emit(["cmd": "tree", "nodes": n])
case "press", "set":
    guard args.count >= 5 else { emit(["error": "args"]); exit(2) }
    let role = args[3], needle = args[4]
    var done = false, err = Int32(0), hit: [String: Any] = [:]
    walk(app) { e, d in
        guard matches(d, role: role, needle: needle) else { return true }
        hit = d
        if cmd == "press" { err = AXUIElementPerformAction(e, kAXPressAction as CFString).rawValue }
        else {
            guard args.count >= 6 else { err = -1; return false }
            err = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, args[5] as CFString).rawValue
        }
        done = true
        return false
    }
    emit(["cmd": cmd, "found": done, "axError": Int(err), "node": hit])
case "focus":
    var f: CFTypeRef? = nil
    let r = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &f)
    if r == .success, let f { emit(["cmd": "focus", "axError": 0, "node": describe(f as! AXUIElement, depth: 0, path: "focused")]) }
    else { emit(["cmd": "focus", "axError": Int(r.rawValue)]) }
case "key", "keytap":
    guard args.count >= 4, let code = UInt16(args[3]) else { emit(["error": "keycode"]); exit(2) }
    var flags: CGEventFlags = []
    for m in args.dropFirst(4) {
        switch m { case "cmd": flags.insert(.maskCommand); case "shift": flags.insert(.maskShift); case "opt": flags.insert(.maskAlternate); case "ctrl": flags.insert(.maskControl); default: emit(["error": "modifier " + m]); exit(2) }
    }
    var posted = 0
    for down in [true, false] {
        if let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) { ev.flags = flags
            // "key" posts to the app pid; "keytap" posts to the session event tap (the frontmost app, incl. a remote Open/Save panel).
            if cmd == "keytap" { ev.post(tap: .cgSessionEventTap) } else { ev.postToPid(pid) }
            posted += 1 }
        usleep(40_000)
    }
    emit(["cmd": cmd, "keycode": Int(code), "flags": args.dropFirst(4).joined(separator: "+"), "eventsPosted": posted])
default:
    emit(["error": "unknown command " + cmd]); exit(2)
}
