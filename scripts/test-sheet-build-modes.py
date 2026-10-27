#!/usr/bin/env python3
"""Real stateLine and observer conditional layout, executed Swift5/6 compiler control.
AppKit is stubbed, observer BODY is stubbed at the same conditional location.
This proves symbol visibility across shipping/test modes, NOT the native SDK.
"""
import pathlib,subprocess,tempfile,os
import sys; sys.path.insert(0,str(__import__('pathlib').Path(__file__).resolve().parent)); from historical_fixture import load, load_bytes
srcpath='Sources/Spacelyzer/SpacelyzerApp.swift'
s=pathlib.Path(srcpath).read_text()
old=load('app-before-observer-scope-fix.swift')
stub='''import Foundation
class NSWindow { var contentView:NSView?; var attachedSheet:NSWindow?; var isSheet=false }
class NSView { var frame=CGRect.zero; var window:NSWindow? }
class NSTableView:NSView { var numberOfRows=1 }
struct Appearance { var name=Name(); struct Name { var rawValue="Aqua" } }
@MainActor enum NSApp { static var keyWindow:NSWindow?; static var effectiveAppearance=Appearance() }
@MainActor enum DemoInput {
 static var window:NSWindow? { nil }
 static func allViews<T>(of type:T.Type)->[T] { [] }
'''
observer='''@MainActor private enum FooterAXEvidence {
 struct Entry { var label="Not scanned"; var value="" }
 struct Result { var entries=[Entry()]; var truncated=false }
 static func inspect(_ root:NSWindow,attachedTo owner:NSWindow?)->Result { Result() }
}
'''
def extract(t):
 # Preserve all source #if/#else/#endif enclosing the observer declaration.
 stack=[]
 for line in t[:t.index('@MainActor private enum FooterAXEvidence')].splitlines():
  x=line.strip()
  if x.startswith('#if '): stack.append(line)
  elif x.startswith('#endif'): stack.pop()
  elif x.startswith('#else') or x.startswith('#elseif '): stack[-1]+='\n'+line
 a=t.index('    static func observedSheetIdentity(');b=t.index('    static func click(',a)
 return stub+t[a:b]+'}\n'+'\n'.join(stack)+'\n'+observer+'\n'+'\n'.join('#endif' for _ in stack)
swift=pathlib.Path(os.environ.get('SWIFT_BIN','/tmp/swift-6.1.2-RELEASE-ubuntu22.04/usr/bin'))/'swiftc'
with tempfile.TemporaryDirectory() as d:
 for label,text in [('old',old),('fixed',s)]:
  p=pathlib.Path(d)/(label+'.swift');p.write_text(extract(text))
  for sv in ['5','6']:
   for mode,flags in [('shipping',[]),('CI',['-D','SPZ_CI_TESTS'])]:
    r=subprocess.run([str(swift),'-swift-version',sv,'-typecheck',*flags,str(p)],capture_output=True,text=True)
    wantfail=label=='old' and mode=='shipping'
    assert (r.returncode!=0)==wantfail,(label,sv,mode,r.stderr)
    if wantfail: assert "cannot find 'FooterAXEvidence' in scope" in r.stderr,r.stderr
    print('PASS',label,'Swift'+sv,mode,'expected missing-observer error' if wantfail else 'typechecks')
