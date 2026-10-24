#!/usr/bin/env python3
"""Compile + run controls for the REAL text of SessionSizeRequest.swift and the docs-capture `windowinfo` case,
against stubs that mirror the declared AppKit / CoreGraphics shapes they use (NSWindow, NSPanel, NSApp.windows,
DemoInput.window/setContentSizeExact, CGWindowListCopyWindowInfo). It proves the source type-checks against those
declared shapes and that the request/report protocol and the window listing format work. It is NOT the macOS SDK:
real AppKit sizing, screen clamping and CGWindowList semantics stay native-unverified."""
import json, os, pathlib, subprocess, tempfile, sys
resp = pathlib.Path('Sources/Spacelyzer/SessionSizeRequest.swift').read_text()
assert resp.count('import AppKit\n') == 1
resp_stubbed = resp.replace('import AppKit\n', '', 1)  # the ONLY edit: AppKit is replaced by the declared stubs below
helper = pathlib.Path('scripts/docs-capture.swift').read_text()
wi = helper[helper.index('case "windowinfo":'):helper.index('case "rect":')].split('\n', 1)[1]
swift = pathlib.Path(os.environ.get('SWIFT_BIN', '/tmp/swift-6.1.2-RELEASE-ubuntu22.04/usr/bin')) / 'swiftc'
appkit = '''
import Foundation
typealias NSSize = CGSize
class NSWindow { var isVisible = true; var isSheet = false; var canBecomeMain = true; var attachedSheet: NSWindow?
  var frame = CGRect(x: 32, y: 42, width: 960, height: 652); var contentLayoutRect = CGRect(x: 0, y: 0, width: 960, height: 625)
  var screen: NSScreen? = NSScreen(); var contentMaxSize = CGSize(); var maxSize = CGSize()
  func setContentSize(_ s: CGSize) { let chrome = frame.height - contentLayoutRect.height
    frame.size = CGSize(width: s.width, height: min(s.height + chrome, NSScreen.visibleH)); contentLayoutRect.size = CGSize(width: s.width, height: frame.height - chrome) } }
final class NSPanel: NSWindow {}
final class NSScreen { static var visibleH = 677.0; var visibleFrame: CGRect { CGRect(x: 0, y: 60, width: 1024, height: NSScreen.visibleH) } }
enum NSApp { static var windows: [NSWindow] = [NSWindow()] }
enum Perf { static func log(_ s: String) { print(s) } }
enum DemoInput {
  @MainActor static var window: NSWindow? { NSApp.windows.first { $0.isVisible && !$0.isSheet && !($0 is NSPanel) && $0.canBecomeMain } }
  @MainActor static func setContentSizeExact(_ window: NSWindow?, _ size: NSSize) { guard let window else { return }
    window.contentMaxSize = NSSize(width: 100_000, height: 100_000); window.maxSize = NSSize(width: 100_000, height: 100_000); window.setContentSize(size) }
}
'''
cg = '''
import Foundation
typealias CGWindowID = UInt32
struct CGWindowListOption: OptionSet { let rawValue: Int; static let optionOnScreenOnly = CGWindowListOption(rawValue: 1); static let excludeDesktopElements = CGWindowListOption(rawValue: 2) }
let kCGNullWindowID: CGWindowID = 0
let kCGWindowOwnerPID = "kCGWindowOwnerPID", kCGWindowNumber = "kCGWindowNumber", kCGWindowBounds = "kCGWindowBounds", kCGWindowLayer = "kCGWindowLayer", kCGWindowAlpha = "kCGWindowAlpha"
func CGWindowListCopyWindowInfo(_ o: CGWindowListOption, _ id: CGWindowID) -> [[String: Any]]? {
  [[kCGWindowOwnerPID: Int32(5), kCGWindowNumber: 11, kCGWindowLayer: 0, kCGWindowAlpha: 1.0, kCGWindowBounds: ["X": 32.0, "Y": 42.0, "Width": 1280.0, "Height": 677.0]],
   [kCGWindowOwnerPID: Int32(5), kCGWindowNumber: 12, kCGWindowLayer: 3, kCGWindowAlpha: 1.0, kCGWindowBounds: ["X": 900.0, "Y": 100.0, "Width": 300.0, "Height": 200.0]],
   [kCGWindowOwnerPID: Int32(5), kCGWindowNumber: 13, kCGWindowLayer: 0, kCGWindowAlpha: 1.0, kCGWindowBounds: ["X": 0.0, "Y": 0.0, "Width": 10.0, "Height": 10.0]],
   [kCGWindowOwnerPID: Int32(9), kCGWindowNumber: 14, kCGWindowLayer: 0, kCGWindowAlpha: 1.0, kCGWindowBounds: ["X": 0.0, "Y": 0.0, "Width": 500.0, "Height": 500.0]]]
}
func list(pid: Int32) {
''' + wi + '''
}
list(pid: 5)
'''
main = '''
MainActor.assumeIsolated {
let pid = ProcessInfo.processInfo.processIdentifier
SessionSizeRequest.start(env: CommandLine.arguments.contains("--off") ? [:] : ["SPZ_SIZE_REQUESTS": "1"])
let mode = CommandLine.arguments.last!
if mode == "tall" { NSScreen.visibleH = 1000 }
if mode == "twowin" { NSApp.windows.append(NSWindow()) }
if mode == "sheet" { NSApp.windows[0].attachedSheet = NSWindow() }
try? "TOKEN1 1280x800\\n".write(toFile: "/tmp/spz-size-request-\\(pid)", atomically: true, encoding: .utf8)
RunLoop.main.run(until: Date().addingTimeInterval(1.6))
print("result:", (try? String(contentsOfFile: "/tmp/spz-size-result-\\(pid)", encoding: .utf8)) ?? "none")
try? FileManager.default.removeItem(atPath: "/tmp/spz-size-request-\\(pid)"); try? FileManager.default.removeItem(atPath: "/tmp/spz-size-result-\\(pid)")
}
'''
def build(t, name, files):
    r = subprocess.run([str(swift), '-DSPZ_CI_TESTS', '-swift-version', '5', *files, '-o', str(t / name)], capture_output=True, text=True)
    if r.returncode: print(r.stdout, r.stderr); raise SystemExit('compile control FAILED: ' + name)
fails = []
def ck(n, ok, d=''):
    print(('ok   ' if ok else 'FAIL ') + n + ('' if ok else ' :: ' + str(d))); (ok or fails.append(n))
with tempfile.TemporaryDirectory() as td:
    t = pathlib.Path(td)
    (t / 'main.swift').write_text(appkit + main); (t / 'resp.swift').write_text(resp_stubbed)
    build(t, 'resp', [str(t / 'main.swift'), str(t / 'resp.swift')])
    def run(mode, off=False):
        o = subprocess.run([str(t / 'resp')] + (['--off'] if off else []) + [mode], capture_output=True, text=True, timeout=30).stdout
        line = [l for l in o.splitlines() if l.startswith('result:')][0][len('result:'):].strip()
        return None if line == 'none' else json.loads(line)
    r = run('wide677')
    ck('real responder text compiles; wide request on a 677-visible screen reports frame 1280x677, token+pid echoed, 1 window', r and r['frameWidth'] == 1280 and abs(r['frameHeight'] - 677) < 1 and r['token'] == 'TOKEN1' and r['ordinaryWindowCount'] == 1 and r['pid'] > 0, r)
    r = run('tall'); ck('tall screen: frame height 800', r and abs(r['frameHeight'] - 800) < 1, r)
    r = run('twowin'); ck('two ordinary windows reported as 2 and not resized', r and r['ordinaryWindowCount'] == 2 and r['frameWidth'] == 960, r)
    r = run('sheet'); ck('attached sheet reported', r and r['sheetAttached'] is True, r)
    r = run('wide677', off=True); ck('inert without SPZ_SIZE_REQUESTS=1: no report written', r is None, r)
    (t / 'cg.swift').write_text(cg.replace('list(pid: 5)\n', '') + '\nlist(pid: 5)\n'); (t / 'cgmain.swift').write_text(cg)
    # compile the real windowinfo case as top-level code (main.swift) so `exit` and the loop are exercised as written
    (t / 'main2.swift').write_text(cg); build(t, 'wi', [str(t / 'main2.swift')])
    o = subprocess.run([str(t / 'wi')], capture_output=True, text=True)
    ck('real windowinfo case compiles and lists only the target pid windows >=50pt as "id layer x y w h"', o.stdout.splitlines() == ['11 0 32 42 1280 677', '12 3 900 100 300 200'], o.stdout)
print('%d failed' % len(fails)); sys.exit(1 if fails else 0)
