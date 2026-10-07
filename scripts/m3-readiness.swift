import Foundation
import ApplicationServices
setbuf(stdout, nil)
// M3 first-run readiness probe (read-only). Waits until the target app shows
// scan-complete evidence ("Scanned in ..." text, ContentView.swift) and the
// scanned fixture root path ("Scanned folder: <path>" accessibility label) in
// its AX tree. Exit: 0 ready, 1 timeout/not-ready, 2 usage, 3 AX trust denied.
let args = CommandLine.arguments
guard args.count == 4, let pid = pid_t(args[1]), let timeout = Double(args[2]) else {
    print("usage: m3-readiness <pid> <timeout_s> <fixtureRootPath>"); exit(2)
}
let want = args[3]
guard AXIsProcessTrusted() else { print("BLOCKED AX trust unavailable; not a measurement"); exit(3) }
let app = AXUIElementCreateApplication(pid)
var seen = Set<UInt>()
func collect(_ el: AXUIElement, _ depth: Int, _ into: inout [String]) {
    guard depth < 20, into.count < 800 else { return }
    let h = CFHash(el)
    if seen.contains(h) { return }
    seen.insert(h)
    for attr in ["AXRole", "AXValue", "AXDescription", "AXHelp", "AXTitle"] {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let s = v as? String { into.append(s) }
    }
    for attr in ["AXWindows", "AXChildren"] {
        var kids: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, attr as CFString, &kids) == .success, let arr = kids as? [AXUIElement] {
            for k in arr { collect(k, depth + 1, &into) }
        }
    }
}
let deadline = ProcessInfo.processInfo.systemUptime + timeout
var scanned = false, rootSeen = false, polls = 0
repeat {
    polls += 1
    seen.removeAll()
    var acc = [String]()
    collect(app, 0, &acc)
    scanned = acc.contains { $0.contains("Scanned in ") }
    rootSeen = acc.contains { $0.contains(want) }
    if scanned && rootSeen { break }
    usleep(250_000)
} while ProcessInfo.processInfo.systemUptime < deadline
print("readiness scanned=\(scanned) root=\(rootSeen) fixture=\(want) polls=\(polls)")
exit(scanned && rootSeen ? 0 : 1)
