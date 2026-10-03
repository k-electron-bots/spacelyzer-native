import Foundation
import AppKit
import ApplicationServices
import Darwin

// External, read-only AX queries plus ordinary mouse/key input on disposable fixtures.
// No Trash/menu actions, attribute writes, trust prompts or app instrumentation.
let args = CommandLine.arguments
guard args.count == 3, let rawPID = Int32(args[1]), let expectedRows = Int(args[2]), expectedRows > 0 else { exit(2) }
guard AXIsProcessTrusted() else { print("BLOCKED AX trust unavailable; not a measurement"); exit(3) }
let app = AXUIElementCreateApplication(rawPID)
struct Record: Codable { let action: String; let elapsedMs: Double; let polls: Int; let selected: String; let rows: Int }
var records = [Record]()
let tickNs: UInt32 = 20_000
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
        // Stop at the table, do not enumerate thousands of row descendants.
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
func rows(_ table: AXUIElement) -> [AXUIElement] { read(table, "AXRows") as? [AXUIElement] ?? [] }
func rowCount(_ table: AXUIElement) -> Int? {
    var count: CFIndex = 0
    return AXUIElementGetAttributeValueCount(table, "AXRows" as CFString, &count) == .success ? count : nil
}
func selected(_ table: AXUIElement) -> String {
    let values = read(table, "AXSelectedRows") as? [AXUIElement] ?? []
    guard values.count == 1 else { return "" }
    // Row description may live on its cell; retain no ambiguous empty identity.
    let row = values[0]
    if !string(row, "AXDescription").isEmpty { return string(row, "AXDescription") }
    let children = read(row, "AXChildren") as? [AXUIElement] ?? []
    let descriptions = children.map { string($0, "AXDescription") }.filter { !$0.isEmpty }
    return descriptions.count == 1 ? descriptions[0] : ""
}
func wait(_ seconds: Double, interval: UInt32 = tickNs, _ condition: () -> Bool) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    repeat { if condition() { return true }; usleep(interval) } while ProcessInfo.processInfo.systemUptime < deadline
    return false
}
// Calibration only. No input posting functions above are called.
guard let running = NSRunningApplication(processIdentifier: rawPID), running.activate(), wait(5, interval: 250_000, { NSWorkspace.shared.frontmostApplication?.processIdentifier == rawPID }), wait(30, interval: 250_000, { one("AXTable", "Folder outline").map { rowCount($0) == expectedRows } == true }), let table = one("AXTable", "Folder outline"), let field = one("AXTextField", "Filter by name") else { exit(4) }
let windows = read(app, "AXWindows") as? [AXUIElement] ?? []
guard windows.count == 1 else { exit(5) }
let window = windows[0]
func point(_ element: AXUIElement, _ name: String) -> [Double]? {
    guard let value = read(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    if name == "AXPosition" { var p = CGPoint.zero; guard AXValueGetValue(value as! AXValue, .cgPoint, &p) else { return nil }; return [Double(p.x), Double(p.y)] }
    var size = CGSize.zero; guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }; return [Double(size.width), Double(size.height)]
}
guard let position = point(window, "AXPosition"), let size = point(window, "AXSize"), size[0] > 0, size[1] > 0 else { exit(6) }
let initialRows = rows(table)
guard initialRows.count == expectedRows else { exit(7) }
func identity(_ row: AXUIElement) -> String {
    if !string(row, "AXDescription").isEmpty { return string(row, "AXDescription") }
    let children = read(row, "AXChildren") as? [AXUIElement] ?? []
    let descriptions = children.map { string($0, "AXDescription") }.filter { !$0.isEmpty }
    return descriptions.count == 1 ? descriptions[0] : ""
}
let first = initialRows.prefix(3).map(identity)
guard first.count == 3, first.allSatisfy({ !$0.isEmpty }), Set(first).count == 3 else { exit(8) }
struct Samples: Codable { let countMs: [Double]; let emptySelectionAttributeMs: [Double]; let heldRowIdentityMs: [Double]; let fieldMs: [Double] }
var countTimes = [Double](), selectedTimes = [Double](), identityTimes = [Double](), fieldTimes = [Double]()
for _ in 0..<100 {
    var start = ProcessInfo.processInfo.systemUptime
    guard rowCount(table) == expectedRows else { exit(9) }
    countTimes.append((ProcessInfo.processInfo.systemUptime-start)*1000)
    start = ProcessInfo.processInfo.systemUptime; guard let selection = read(table, "AXSelectedRows") as? [AXUIElement], selection.isEmpty else { exit(11) }
    selectedTimes.append((ProcessInfo.processInfo.systemUptime-start)*1000)
    start = ProcessInfo.processInfo.systemUptime; guard identity(initialRows[1]) == first[1] else { exit(12) }
    identityTimes.append((ProcessInfo.processInfo.systemUptime-start)*1000)
    start = ProcessInfo.processInfo.systemUptime; guard string(field, "AXValue").isEmpty else { exit(10) }
    fieldTimes.append((ProcessInfo.processInfo.systemUptime-start)*1000)
    usleep(20_000)
}
struct Output: Codable { let kind: String; let pid: Int32; let rows: Int; let position: [Double]; let size: [Double]; let firstIdentities: [String]; let samples: Samples }
let result = Output(kind: "calibration-only", pid: rawPID, rows: expectedRows, position: position, size: size, firstIdentities: first, samples: Samples(countMs: countTimes, emptySelectionAttributeMs: selectedTimes, heldRowIdentityMs: identityTimes, fieldMs: fieldTimes))
FileHandle.standardOutput.write(try JSONEncoder().encode(result))
