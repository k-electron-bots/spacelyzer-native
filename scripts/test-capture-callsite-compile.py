#!/usr/bin/env python3
"""Compile control for the two NEW macOS call sites in SpacelyzerApp.swift.
The REAL source text is extracted and type-checked and run against stubs that mirror
the declared AppKit/ApplicationServices/AppModel shapes. Proves it compiles against
those stubs and that the sheet fallback wiring behaves; it is NOT the macOS SDK."""
import os,pathlib,re,subprocess,tempfile
s=pathlib.Path('Sources/Spacelyzer/SpacelyzerApp.swift').read_text()
fp=s[s.index('fingerprint: {')+len('fingerprint: {'):s.index('})\n                            if !acked')]
blk=s[s.index('func axArray('):s.index('axVisit(sheet, depth: 0, edge: "axuielement-attached-sheet-\\(selection.route.rawValue)")')+len('axVisit(sheet, depth: 0, edge: "axuielement-attached-sheet-\\(selection.route.rawValue)")')]
blk+='\n                    }'  # close `if let sheet`
sel=pathlib.Path('Sources/Spacelyzer/AttachedSheetSelection.swift').read_text()
ack=pathlib.Path('Sources/Spacelyzer/CaptureAckWait.swift').read_text()
stub='''
import Foundation
typealias CFTypeRef = AnyObject
typealias CFString = String
final class AXUIElement { let role:String; var kids:[AXUIElement]; init(_ r:String,_ k:[AXUIElement]=[]){role=r;kids=k} }
struct AXError:Equatable { var rawValue:Int32; static let success=AXError(rawValue:0) }
let kAXRoleAttribute="AXRole"
var scenario="unique-children"
final class Box { let v:[AXUIElement]; init(_ v:[AXUIElement]){self.v=v} }
let sheetEl=AXUIElement("AXSheet"), group=AXUIElement("AXGroup")
func AXUIElementCopyAttributeValue(_ e:AXUIElement,_ k:CFString,_ out:UnsafeMutablePointer<CFTypeRef?>)->AXError {
 switch k {
 case "AXSheets": return AXError(rawValue:-25205)
 case "AXChildren": out.pointee = (scenario=="two" ? [sheetEl,AXUIElement("AXSheet")] : [group,sheetEl]) as NSArray; return .success
 case "AXRole": out.pointee = (e.role as NSString); return .success
 default: return AXError(rawValue:-25205) }
}
enum Perf { static func log(_ s:String){ print(s) } }
struct Size { var width=1280.0, height=800.0 }
final class V { var frame=CGRect(x:0,y:0,width:1280,height:800) }
final class W { var contentView:V?=V(); var attachedSheet:W? }
enum DemoInput { @MainActor static var window:W? = W() }
struct AName { var rawValue="Aqua" }; struct Appearance { var name=AName() }
enum NSApp { static var effectiveAppearance=Appearance() }
enum TrailingTab: Hashable { case treemap, kinds, largest, folders }
enum FileCategory { case video }
final class Model { var removalMessage:String?; var tab:TrailingTab = .treemap; var selected:UInt32?; var selectedSet:[UInt32]=[]; var outlineRows:[Int]=[]; var expanded:Set<UInt32>=[]; var filterKind:FileCategory?; var filterMinMB=0; var filterText="" }
class NSView {}
final class NSTableView:NSView { var numberOfRows=3 }
final class Clip { var bounds=CGRect(x:0,y:12,width:1,height:1) }
final class NSScrollView:NSView { var contentView=Clip() }
extension DemoInput { @MainActor static func allViews<T:NSView>(of t:T.Type)->[T] { [T]() } }
@MainActor let model=Model()
@MainActor func fingerprint()->String {
'''+fp+'''
}
var discovered=0, axWalkAvailable=false, walked=0
func axVisit(_ e:AXUIElement, depth:Int, edge:String){ walked+=1; print("walk",edge) }
@MainActor func selectionSite(owners:[AXUIElement]){
 do {
'''+blk.replace('owners[0]','owners[0]')+'''
 }
}
@main struct M { @MainActor static func main(){
 print(fingerprint())
 selectionSite(owners:[AXUIElement("AXWindow")])
 let ok = walked==1 && (scenario=="two" ? false : true)
 exit(ok ? 0 : 1)
}}
'''
swift=pathlib.Path(os.environ.get('SWIFT_BIN','/tmp/swift-6.1.2-RELEASE-ubuntu22.04/usr/bin'))/'swiftc'
with tempfile.TemporaryDirectory() as t:
 p=pathlib.Path(t);(p/'main.swift').write_text(stub.replace('@main struct M { @MainActor static func main(){','@MainActor func _m(){').replace('}}\n','}\n') + '\nMainActor.assumeIsolated { _m() }\n')
 (p/'sel.swift').write_text(sel);(p/'ack.swift').write_text(ack)
 r=subprocess.run([str(swift),'-DSPZ_CI_TESTS','-swift-version','5',str(p/'main.swift'),str(p/'sel.swift'),str(p/'ack.swift'),'-o',str(p/'t')],capture_output=True,text=True)
 if r.returncode:print(r.stdout,r.stderr);raise SystemExit('compile control FAILED')
 o=subprocess.run([str(p/'t')],capture_output=True,text=True);print(o.stdout)
 assert o.returncode==0,o
 assert 'route=AXChildren-role-AXSheet selected=true' in o.stdout and 'walk axuielement-attached-sheet-AXChildren-role-AXSheet' in o.stdout
 print('PASS real call-site text compiles against stubs; fallback route wired')
