#!/usr/bin/env python3
"""Linux compile + behavior control for the REAL text of the footer-discovery block in scripts/m3-interaction-bench.swift (dump on non-unique match, then one strict
fail-closed rule). Extracted verbatim and compiled against stubs of the AX helpers it uses; not the macOS SDK. Cases: unique match (no dump), three matches with exactly
one strict match (proceeds, dump written), two strict (abort 7), none strict (abort 7)."""
import json, os, pathlib, subprocess, sys, tempfile
src = pathlib.Path('scripts/m3-interaction-bench.swift').read_text()
a = src.index('    let walkAll = descendants()'); b = src.index('    // One footer text read'); block = src[a:b]
assert 'exit(7)' in block and 'footer_nonunique_dump' in block
swift = pathlib.Path(os.environ.get('SWIFT_BIN', '/tmp/swift-6.1.2-RELEASE-ubuntu22.04/usr/bin')) / 'swiftc'
prog = '''import Foundation
final class AXUIElement { let a: [String: String]; init(_ a: [String: String]) { self.a = a } }
func CFEqual(_ x: AXUIElement, _ y: AXUIElement) -> Bool { x === y }
struct R { var x = 0.0 }
func string(_ e: AXUIElement, _ n: String) -> String { e.a[n] ?? "" }
func frame(_ e: AXUIElement) -> R? { R() }
var emitted: [[String: Any]] = []
func emit(_ o: [String: Any]) { emitted.append(o) }
var tree: [AXUIElement] = []
func descendants() -> [AXUIElement] { tree }
func run() {
''' + block + '''
    print("PROCEEDED \\(footer.a["AXValue"] ?? "")")
    emit(["proceeded": true])
}
let mode = CommandLine.arguments[1]
let sum = "/x/typing-200k 4 GB in 202,001 items"
let plain = AXUIElement(["AXRole": "AXStaticText", "AXLabel": "Scanned folder: /x"])
let helpOnly = AXUIElement(["AXRole": "AXStaticText", "AXValue": "Scan summary", "AXHelp": sum])
let valSum = AXUIElement(["AXRole": "AXStaticText", "AXValue": sum, "AXHelp": sum])
let treemap = AXUIElement(["AXRole": "AXUnknown", "AXHelp": "Shows each item as a region. The outline and the Largest list offer the same items to VoiceOver.", "AXDescription": "Treemap"])
switch mode {
case "unique": tree = [plain, AXUIElement(["AXRole": "AXStaticText", "AXValue": sum, "AXHelp": sum])]
case "one": tree = [plain, helpOnly, valSum, treemap]
case "two": tree = [helpOnly, valSum, AXUIElement(["AXRole": "AXStaticText", "AXValue": sum + " copy"]), treemap]
default: tree = [helpOnly, treemap, AXUIElement(["AXValue": "12 items"])]
}
run()
let d = try! JSONSerialization.data(withJSONObject: emitted.map { $0.keys.sorted() })
print("EMITTED " + String(data: d, encoding: .utf8)!)
'''
t = pathlib.Path(tempfile.mkdtemp()); (t / 'm.swift').write_text(prog.replace('exit(7)', 'Foundation.exit(7)'))
r = subprocess.run([str(swift), '-swift-version', '5', str(t / 'm.swift'), '-o', str(t / 'm')], capture_output=True, text=True); assert r.returncode == 0, r.stderr[-1500:]
def go(m): return subprocess.run([str(t / 'm'), m], capture_output=True, text=True)
u = go('unique'); assert u.returncode == 0 and 'PROCEEDED' in u.stdout and 'footer_nonunique_dump' not in u.stdout and 'footer-candidate' not in u.stdout, u.stdout
o = go('one'); assert o.returncode == 0 and 'PROCEEDED /x/typing-200k 4 GB in 202,001 items' in o.stdout and 'footer-candidate[0]' in o.stdout and '1 of 3 remain' in o.stdout and 'footer-candidate[1]' in o.stdout, o.stdout
w = go('two'); assert w.returncode == 7 and 'PROCEEDED' not in w.stdout and 'footer-candidate[0]' in w.stdout and 'footer-candidate[2]' in w.stdout, (w.returncode, w.stdout)
n = go('none'); assert n.returncode == 7 and 'PROCEEDED' not in n.stdout and 'footer-candidate[0]' in n.stdout and '0 of 3 remain' in n.stdout, (n.returncode, n.stdout)
assert 'footer_nonunique_dump' in o.stdout.split('EMITTED')[1] and 'footer_nonunique_dump' not in u.stdout.split('EMITTED')[1] and '2 left after' in w.stdout, 'emit records'
print('PASS m3 footer discovery block: compiles; unique proceeds without dump; one strict match proceeds with dump; ambiguous aborts 7 with dump (stubs, not a Mac result)')
