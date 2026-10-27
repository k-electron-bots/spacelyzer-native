#!/usr/bin/env python3
"""Execute real pure sheet classifier + source-scoping checks; not Mac AX evidence."""
import pathlib, subprocess, tempfile,os
import sys; sys.path.insert(0,str(__import__('pathlib').Path(__file__).resolve().parent)); from historical_fixture import load, load_bytes
s=pathlib.Path('Sources/Spacelyzer/SpacelyzerApp.swift').read_text()
a=s.index('    static func observedSheetIdentity(');b=s.index('\n    }',a)+6
method=s[a:b]
old=load('app-before-sheet-text-collector-fix.swift')
oldline=next(x.strip() for x in old.splitlines() if 'let texts = allViews(of: NSTextField.self).filter' in x)
oldcontrol='class Win {}\nclass NSTextField { var window:Win?; var stringValue="" }\nlet attached=Win()\nfunc allViews<T>(of type:T.Type)->[T] { [] }\n'+oldline+'\nprecondition(!texts.contains("Not scanned")); print("PASS original collector misses proxy-only text, real AX classifier recovers it")\n'
checks=oldcontrol+'''
precondition(Probe.observedSheetIdentity(["Not scanned"], complete:true)=="notscanned")
precondition(Probe.observedSheetIdentity(["Moved Backup.zip to the Trash."], complete:true)=="removal-result")
precondition(Probe.observedSheetIdentity([], complete:true)=="unknown")
precondition(Probe.observedSheetIdentity(["Move to Trash?"], complete:true)=="unknown")
precondition(Probe.observedSheetIdentity(["Not scanned"], complete:false)=="unknown")
print("PASS real classifier hosted text, result, empty, wrong dialog, truncation")
'''
with tempfile.TemporaryDirectory() as t:
 p=pathlib.Path(t);(p/'main.swift').write_text('enum Probe {\n'+method+'\n}\n'+checks)
 swift=pathlib.Path(os.environ.get('SWIFT_BIN','/tmp/swift-6.1.2-RELEASE-ubuntu22.04/usr/bin'))/'swiftc'
 subprocess.run([str(swift),str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
state=s[s.index('static func stateLine('):s.index('static func click(',s.index('static func stateLine('))]
assert 'FooterAXEvidence.inspect(attached, attachedTo: w)' in state
assert 'complete: !observed.truncated' in state
assert 'NSTextField.self' not in state
print('PASS collector scope is actual attached sheet, not global labels or intent; truncation refuses')

assert 'owner.attachedSheet === root, owners.count == 1' in s
assert 'owner.attachedSheet === root, owners.count == 1' in s
sel=pathlib.Path('Sources/Spacelyzer/AttachedSheetSelection.swift').read_text()
assert 'AttachedSheetSelection<AXUIElement>.select(' in s and 'owner: owners[0]' in s
assert 'if let sheet = selection.sheet' in s and 'axVisit(sheet,' in s
assert 'footer-ax sheet-selection route=' in s
assert 'if list.count == 1' in sel and 'matches.count == 1' in sel
assert 's.rc != attributeUnsupported && s.rc != noValue' in sel
assert 'sheets.count == 1' not in s
print('PASS exported tree requires unique owner and exactly one attached sheet (AXSheets primary, role-AXSheet fallback only for unsupported/empty), route logged, no title-only sheet guess')
