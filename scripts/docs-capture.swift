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
    string(element, "AXTitle") == text || string(element, "AXDescription") == text || string(element, "AXValue") == text
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
case "escape":
    NSRunningApplication(processIdentifier: pid)?.activate()
    usleep(300_000)
    post(key: 53)
default:
    exit(2)
}
