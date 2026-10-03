import Foundation
import ApplicationServices
import Darwin
setbuf(stdout, nil)
// Read-only diagnostic. Never prompt for trust, set attributes, or synthesize labels.
let pid = pid_t(CommandLine.arguments.dropFirst().first.flatMap(Int32.init) ?? 0)
print("ax-client targetPID=\(pid) clientPID=\(getpid()) trusted=\(AXIsProcessTrusted())")
guard pid > 0, AXIsProcessTrusted() else { print("INCONCLUSIVE trust denied or invalid PID; no accessibility absence conclusion"); exit(0) }
let root = AXUIElementCreateApplication(pid)
var footerMatched = false
var matchedDetails = false
let expectedPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
let resultPath = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : ""
let expected = try? Data(contentsOf: URL(fileURLWithPath: expectedPath))
var seen: [AXUIElement] = []
var truncated = false
func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name, &value)
    print("attribute name=\(name) error=\(error.rawValue)")
    return error == .success ? value : nil
}
func visit(_ element: AXUIElement, depth: Int, edge: String, inFooter: Bool) {
    guard depth < 24, seen.count < 512 else { truncated = true; return }
    guard !seen.contains(where: { CFEqual($0, element) }) else { return }
    seen.append(element)
    var actualPID: pid_t = 0
    let pidError = AXUIElementGetPid(element, &actualPID)
    print("node index=\(seen.count) edge=\(edge) depth=\(depth) pid=\(actualPID) pidError=\(pidError.rawValue)")
    let title = attribute(element, kAXTitleAttribute as CFString) as? String
    let role = attribute(element, kAXRoleAttribute as CFString) as? String
    let isFooter = title == "CI constrained production footer (700 pt)" && role == kAXWindowRole && pidError == .success && actualPID == pid
    if isFooter { footerMatched = true }
    let footerScope = inFooter || isFooter
    print("scope footer700pt=\(footerScope) exactWindowMatched=\(isFooter)")
    if footerScope, pidError == .success, actualPID == pid, role == kAXStaticTextRole, let expected, !expected.isEmpty {
        let help = attribute(element, kAXHelpAttribute as CFString) as? String
        let value = attribute(element, kAXValueAttribute as CFString) as? String
        if help.map({ Data($0.utf8) }) == expected && value.map({ Data($0.utf8) }) == expected {
            matchedDetails = true
            print("external-footer-same-node-exact-details matched node=\(seen.count)")
        }
    }
    for name in [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute] {
        if let value = attribute(element, name as CFString) { print("value \(name)=\(String(describing: value))") }
    }
    for name in [kAXWindowsAttribute, kAXChildrenAttribute] {
        guard let children = attribute(element, name as CFString) as? [AXUIElement] else { continue }
        for child in children {
            if seen.count >= 512 { truncated = true; break }
            visit(child, depth: depth + 1, edge: name, inFooter: footerScope)
        }
        if seen.count >= 512 { break }
    }
}
visit(root, depth: 0, edge: "application-root", inFooter: false)
print("ax-client complete footerWindowMatched=\(footerMatched) nodes=\(seen.count) truncated=\(truncated); diagnostic only, separate from strict native accessor gate")

let verified = footerMatched && matchedDetails && !truncated && expected != nil
print("external-footer-regression verified=\(verified) sameNodeHelpValue=\(matchedDetails); native accessor gate remains separate")
if !resultPath.isEmpty { try? (verified ? "VERIFIED" : "INCONCLUSIVE_OR_FAILED").write(toFile: resultPath, atomically: true, encoding: .utf8) }
