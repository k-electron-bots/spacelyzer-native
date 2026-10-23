#!/usr/bin/env python3
"""Execute the REAL nosheet command body against declared offline AX graphs.
Not a macOS AX/SDK proof. Unknown roles/children and bounded walks must refuse.
"""
import pathlib, subprocess, tempfile, os
s=pathlib.Path('scripts/docs-capture.swift').read_text()
body=s.split('case "nosheet":',1)[1].split('case "sheettext":',1)[0]
stub='''import Foundation
import Glibc
typealias AXUIElement = String
typealias CFTypeRef = Any
enum AXError { case success, attributeUnsupported, noValue, cannotComplete }
let scenario=CommandLine.arguments[1], app="app"
func read(_ el: String, _ name:String)->Any? {
 if name=="AXWindows" { return scenario=="windows-error" ? nil : ["window"] }
 if name=="AXRole" {
  if scenario=="role-error", el=="leaf" { return nil }
  if el=="window" { return "AXWindow" }
  if scenario=="sheet" { return "AXSheet" }
  if scenario=="popover" { return "AXPopover" }
  if scenario=="dialog" { return "AXWindow" }
  return "AXStaticText"
 }
 if name=="AXSubrole", scenario=="dialog", el=="leaf" { return "AXDialog" }
 return nil
}
func string(_ el:String,_ name:String)->String { read(el,name) as? String ?? "" }
func AXUIElementCopyAttributeValue(_ el:String,_ name:String,_ result:inout Any?)->AXError {
 if el=="window" { result=["leaf"]; return .success }
 if scenario=="children-error" { return .cannotComplete }
 if scenario=="invalid-children" { result="bad"; return .success }
 if scenario=="cycle" { result=["leaf"]; return .success }
 return scenario=="unsupported" ? .attributeUnsupported : .noValue
}
'''
with tempfile.TemporaryDirectory() as t:
 p=pathlib.Path(t);(p/'main.swift').write_text(stub+body.replace(' as CFString',''))
 swift=pathlib.Path(os.environ.get('SWIFT_BIN','/tmp/swift-6.1.2-RELEASE-ubuntu22.04/usr/bin'))/'swiftc'
 subprocess.run([str(swift),str(p/'main.swift'),'-o',str(p/'test')],check=True)
 for scenario, expected in [('clear',0),('unsupported',0),('sheet',1),('popover',1),('dialog',1),('windows-error',1),('role-error',1),('children-error',1),('invalid-children',1),('cycle',1)]:
  r=subprocess.run([str(p/'test'),scenario],capture_output=True,text=True)
  assert r.returncode==expected,(scenario,r.returncode,r.stdout,r.stderr)
  print('PASS real nosheet body',scenario,'rc='+str(r.returncode))
