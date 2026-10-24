#!/usr/bin/env python3
"""Execute actual external probe logic on declared AX graphs, NOT Mac evidence."""
import pathlib,subprocess,tempfile,os
s=pathlib.Path('scripts/sheet-probe.swift').read_text();body=s[s.index('struct SheetProbeResult'):s.index('\nlet args = CommandLine.arguments')].replace(' as CFString','')
stub='''import Foundation
import Glibc
typealias AXUIElement=String
typealias CFTypeRef=Any
typealias pid_t=Int32
enum AXError:Int32 {case success=0,attributeUnsupported = -25205,noValue = -25212,cannotComplete = -25204}
let scenario=CommandLine.arguments[1]
func AXIsProcessTrusted()->Bool {scenario != "untrusted"}
func AXUIElementCreateApplication(_ pid:Int32)->String {"app"}
func CFEqual(_ a:String,_ b:String)->Bool {a==b}
func CFGetTypeID(_ value:Any)->Int { value is String ? 1 : 2 }
func AXUIElementGetTypeID()->Int {1}
func AXUIElementGetPid(_ el:String,_ pid:inout Int32)->AXError {pid=scenario=="wrongpid" && el=="title" ? 999 : 42; return .success}
func AXUIElementCopyAttributeValue(_ el:String,_ key:String,_ value:inout Any?)->AXError {
 if scenario=="error",el=="sheet",key=="AXChildren" {return .cannotComplete}
 if key=="AXFocusedWindow" && el=="app" {value=scenario=="badfocus" ? 123 : (scenario=="stale" ? "background" : "sheet");return .success}
 if key=="AXWindows" && el=="app" {value=["window"];return .success}
 if key=="AXRole" {value=el=="window" ? "AXWindow" : (el=="sheet" || el=="other" ? "AXSheet" : el=="row" ? "AXRow" : "AXStaticText"); return .success}
 if key=="AXSheets",el=="window",["sheets-only","dag"].contains(scenario) {value=["sheet"];return .success}
 if key=="AXChildren" {
  if el=="window" {value=["none","sheets-only"].contains(scenario) ? ["background"] : scenario=="multiple" ? ["sheet","other"] : ["sheet","background"];return .success}
  if el=="sheet" {
   value=scenario=="cycle" ? ["sheet"] : scenario=="cap" ? (0..<2100).map {"n\\($0)"} : scenario=="empty" ? ["title","qualifier"] : ["title","qualifier","row"];return .success
  }
  return .attributeUnsupported
 }
 if key=="AXValue" {
  if el=="title" {value=scenario=="wrong" ? "Move to Trash?" : "Not scanned";return .success}
  if el=="qualifier" {value=scenario=="conflict" ? "Moved Backup.zip to the Trash." : "These locations were not scanned, so they are not in the totals.";return .success}
  if el=="background" {value="Not scanned";return .success}
 }
 return .noValue
}
'''
with tempfile.TemporaryDirectory() as t:
 p=pathlib.Path(t);(p/'main.swift').write_text(stub+body+'''\nlet r=probeSheet(pid:42,step:78,token:"capture-unique")
print(r.identity,r.complete,r.reason)
exit(r.complete ? 0 : 1)
''')
 swift=pathlib.Path(os.environ.get('SWIFT_BIN','/tmp/swift-6.1.2-RELEASE-ubuntu22.04/usr/bin'))/'swiftc'
 subprocess.run([str(swift),str(p/'main.swift'),'-o',str(p/'test')],check=True)
 for scenario in ['good','none','multiple','wrong','conflict','empty','wrongpid','error','cycle','cap','untrusted','stale','badfocus','sheets-only','dag']:
  r=subprocess.run([str(p/'test'),scenario],capture_output=True,text=True)
  assert r.returncode==(0 if scenario in ['good','sheets-only','dag'] else 1),(scenario,r.stdout,r.stderr)
  print('PASS',scenario,r.stdout.strip())
