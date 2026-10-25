#!/usr/bin/env python3
"""Linux compile + behavior controls for the REAL text of scripts/ship-ui.swift against stubs that mirror the declared
ApplicationServices/CoreGraphics shapes it uses. It proves the source type-checks against those shapes and that the
tree/press/set/focus/key command logic and JSON output work on a fake AX tree. It is NOT the macOS SDK: real AX trust,
attribute values, key delivery and panel structure stay native-unverified until a Mac run."""
import json, os, pathlib, subprocess, tempfile, sys
src = pathlib.Path('scripts/ship-ui.swift').read_text()
for imp in ('import ApplicationServices\n', 'import CoreGraphics\n', 'import Darwin\n'):
    assert src.count(imp) == 1, imp
body = src
for imp in ('import ApplicationServices\n', 'import CoreGraphics\n', 'import Darwin\n'):
    body = body.replace(imp, '', 1)  # the ONLY edit: the system modules are replaced by the declared stubs below
swift = pathlib.Path(os.environ.get('SWIFT_BIN', '/tmp/swift-6.1.2-RELEASE-ubuntu22.04/usr/bin')) / 'swiftc'
stub = '''
import Foundation
typealias CFTypeRef = Any
typealias CFString = String
typealias pid_t_ = Int32
final class AXUIElement { let a: [String: Any]; var kids: [AXUIElement]; init(_ a: [String: Any], _ k: [AXUIElement] = []) { self.a = a; kids = k }
  var pressed = false; var setValue: String? }
struct AXError: Equatable { var rawValue: Int32; static let success = AXError(rawValue: 0); static let noValue = AXError(rawValue: -25212) }
let kAXEnabledAttribute = "AXEnabled", kAXFocusedAttribute = "AXFocused", kAXValueAttribute = "AXValue", kAXRoleAttribute = "AXRole"
let kAXSubroleAttribute = "AXSubrole", kAXTitleAttribute = "AXTitle", kAXDescriptionAttribute = "AXDescription", kAXIdentifierAttribute = "AXIdentifier"
let kAXChildrenAttribute = "AXChildren", kAXPressAction = "AXPress", kAXFocusedUIElementAttribute = "AXFocusedUIElement"
nonisolated(unsafe) var fake: AXUIElement = AXUIElement([:])
nonisolated(unsafe) var focusedFake: AXUIElement? = nil
nonisolated(unsafe) var trusted = true
func AXIsProcessTrusted() -> Bool { trusted }
func AXUIElementCreateApplication(_ p: Int32) -> AXUIElement { fake }
func AXUIElementCopyAttributeValue(_ e: AXUIElement, _ n: CFString, _ v: UnsafeMutablePointer<CFTypeRef?>) -> AXError {
  if n == kAXChildrenAttribute { v.pointee = e.kids; return .success }
  if n == kAXFocusedUIElementAttribute { if let f = focusedFake { v.pointee = f; return .success }; return .noValue }
  if let x = e.a[n] { v.pointee = x; return .success }
  return .noValue }
func AXUIElementPerformAction(_ e: AXUIElement, _ a: CFString) -> AXError { e.pressed = true; return .success }
func AXUIElementSetAttributeValue(_ e: AXUIElement, _ n: CFString, _ v: CFTypeRef) -> AXError { e.setValue = v as? String; return .success }
struct CGEventFlags: OptionSet { let rawValue: UInt64; static let maskCommand = CGEventFlags(rawValue: 1); static let maskShift = CGEventFlags(rawValue: 2)
  static let maskAlternate = CGEventFlags(rawValue: 4); static let maskControl = CGEventFlags(rawValue: 8) }
final class CGEvent { var flags: CGEventFlags = []
  init?(keyboardEventSource: AnyObject?, virtualKey: UInt16, keyDown: Bool) {}
  func postToPid(_ p: Int32) { print("{\\"stub\\":\\"post\\",\\"flags\\":\\(flags.rawValue)}") } }
'''
# Harness: the helper text is its top-level script; the stub fake tree is built by a prelude selected by SHIP_FAKE.
prelude = '''
if let m = ProcessInfo.processInfo.environment["SHIP_FAKE"] {
  let save = AXUIElement(["AXRole": "AXButton", "AXTitle": "Save"])
  let name = AXUIElement(["AXRole": "AXTextField", "AXIdentifier": "saveAsNameTextField", "AXValue": "spacelyzer-largest.csv"])
  let panel = AXUIElement(["AXRole": "AXWindow", "AXSubrole": "AXDialog", "AXTitle": "Save"], [name, save])
  let exp = AXUIElement(["AXRole": "AXButton", "AXDescription": "Export the Largest list as CSV", "AXEnabled": m != "disabled"])
  fake = AXUIElement(["AXRole": "AXApplication"], [AXUIElement(["AXRole": "AXWindow", "AXTitle": "Spacelyzer"], [exp]), panel])
  focusedFake = exp
  trusted = m != "untrusted"
}
'''
with tempfile.TemporaryDirectory() as d:
    d = pathlib.Path(d)
    (d / 'main.swift').write_text(stub + prelude + body)
    r = subprocess.run([str(swift), '-swift-version', '5', str(d / 'main.swift'), '-o', str(d / 'ui')], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr[-3000:]
    def run(mode, *a):
        env = dict(os.environ, SHIP_FAKE=mode)
        p = subprocess.run([str(d / 'ui'), *a], capture_output=True, text=True, env=env)
        return p.returncode, [json.loads(l) for l in p.stdout.splitlines() if l.strip().startswith('{')]
    rc, o = run('ok', 'tree', '42'); assert rc == 0 and o[-1] == {'cmd': 'tree', 'nodes': 6}, o
    assert any(x.get('desc') == 'Export the Largest list as CSV' for x in o)
    rc, o = run('ok', 'press', '42', 'AXButton', 'Export the Largest'); assert o[-1]['found'] and o[-1]['axError'] == 0, o
    rc, o = run('ok', 'press', '42', 'AXButton', '=Largest'); assert o[-1]['found'] is False, o   # exact: not the Export button
    rc, o = run('ok', 'press', '42', 'AXButton', '=Export the Largest list as CSV'); assert o[-1]['found'] and o[-1]['axError'] == 0, o
    rc, o = run('ok', 'press', '42', 'AXButton', 'Nope'); assert o[-1]['found'] is False, o
    rc, o = run('ok', 'set', '42', 'AXTextField', 'saveAsNameTextField', '/tmp/x.csv'); assert o[-1]['found'], o
    rc, o = run('ok', 'focus', '42'); assert o[-1]['node']['desc'].startswith('Export'), o
    rc, o = run('ok', 'key', '42', '31', 'cmd', 'shift'); assert o[-1]['eventsPosted'] == 2 and o[-1]['flags'] == 'cmd+shift', o
    assert any(x.get('stub') == 'post' and x['flags'] == 3 for x in o), o
    rc, o = run('ok', 'key', '42', '31', 'bogus'); assert rc == 2, (rc, o)
    rc, o = run('untrusted', 'tree', '42'); assert rc == 3 and o[0]['error'] == 'not-trusted', (rc, o)
    rc, o = run('disabled', 'tree', '42'); assert any(x.get('enabled') is False for x in o), o
print('PASS ship-ui.swift type-checks against the declared shapes; tree/press/set/focus/key/untrusted/bad-modifier behave on a fake AX tree (Linux stubs, not macOS)')
