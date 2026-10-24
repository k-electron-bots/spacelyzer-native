#!/usr/bin/env python3
"""Executed Linux control for AttachedSheetSelection with fake elements.
Proves selection rules only, not AX behavior or the macOS call site."""
import os,pathlib,subprocess,tempfile
src=pathlib.Path('Sources/Spacelyzer/AttachedSheetSelection.swift').read_text()
swift=pathlib.Path(os.environ.get('SWIFT_BIN','/tmp/swift-6.1.2-RELEASE-ubuntu22.04/usr/bin'))/'swiftc'
main='''
import Foundation
typealias S = AttachedSheetSelection<String>
func run(_ sheets:(Int32,[String]?), _ kids:(Int32,[String]?), _ roles:[String:(Int32,String?)]) -> S.Outcome {
 S.select(owner:"w", sheets:{_ in sheets}, children:{_ in kids}, role:{ roles[$0] ?? (-25212,nil) })
}
let sc=CommandLine.arguments[1]
var o:S.Outcome
switch sc {
case "axsheets-unique": o=run((0,["s"]),(0,nil),[:]); exit(o.sheet=="s" && o.route == .axSheets ? 0:1)
case "axsheets-multiple": o=run((0,["a","b"]),(0,["x"]),["x":(0,"AXSheet")]); exit(o.sheet==nil && o.route == .none ? 0:1)
case "unsupported-unique-child": o=run((-25205,nil),(0,["g","s"]),["g":(0,"AXGroup"),"s":(0,"AXSheet")]); exit(o.sheet=="s" && o.route == .axChildrenRole ? 0:1)
case "unsupported-two-children": o=run((-25205,nil),(0,["s1","s2"]),["s1":(0,"AXSheet"),"s2":(0,"AXSheet")]); exit(o.sheet==nil ? 0:1)
case "unsupported-no-sheet-child": o=run((-25205,nil),(0,["g"]),["g":(0,"AXGroup")]); exit(o.sheet==nil ? 0:1)
case "other-error-no-fallback": o=run((-25204,nil),(0,["s"]),["s":(0,"AXSheet")]); exit(o.sheet==nil && o.reason.contains("-25204") ? 0:1)
case "empty-success-falls-back": o=run((0,[]),(0,["s"]),["s":(0,"AXSheet")]); exit(o.sheet=="s" && o.route == .axChildrenRole ? 0:1)
case "children-error": o=run((-25205,nil),(-25204,nil),[:]); exit(o.sheet==nil ? 0:1)
case "role-unreadable-fail-closed": o=run((-25205,nil),(0,["s","u"]),["s":(0,"AXSheet"),"u":(-25204,nil)]); exit(o.sheet==nil ? 0:1)
default: exit(2)
}
'''
with tempfile.TemporaryDirectory() as t:
 p=pathlib.Path(t);(p/'main.swift').write_text(main);(p/'a.swift').write_text(src)
 subprocess.run([str(swift),'-DSPZ_CI_TESTS',str(p/'main.swift'),str(p/'a.swift'),'-o',str(p/'t')],check=True)
 for sc in ['axsheets-unique','axsheets-multiple','unsupported-unique-child','unsupported-two-children','unsupported-no-sheet-child','other-error-no-fallback','empty-success-falls-back','children-error','role-unreadable-fail-closed']:
  r=subprocess.run([str(p/'t'),sc]);assert r.returncode==0,sc;print('PASS',sc)
