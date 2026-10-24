#!/usr/bin/env python3
"""Source-derived presentation-host and action controls. NOT a SwiftUI runtime.
Compile/run the actual button action in shipping/CI Swift5/6 with declared model
seams. Structural host lifetime model removes toolbar hosts under overflow;
proves old dependency and new stable attachment, NOT native presentation/pixels.
"""
import pathlib,re,subprocess,tempfile,os
path='Sources/Spacelyzer/ContentView.swift'
new=pathlib.Path(path).read_text()
old=subprocess.run(['git','show','efa2e9fe96c0705e4315575a9147795b23841ed6:'+path],check=True,capture_output=True,text=True).stdout

def block(source,start):
 opening=source.index('{',start);depth=1;i=opening+1
 while depth:
  if source[i]=='{':depth+=1
  if source[i]=='}':depth-=1
  i+=1
 return opening,i

def connection(source):
 toolbar=block(source,source.index('.toolbar {'))
 pop=source.index('.popover(isPresented: $showRemovalHistory)')
 # The host class is derived from actual modifier placement, not supplied by test.
 host='toolbar' if toolbar[0]<pop<toolbar[1] else 'root'
 label=source.index('Label("Removed",');button=source.rfind('Button {',0,label)
 a,b=block(source,button);action=source[a+1:b-1]
 assert 'showRemovalHistory = true' in action
 assert source.count('.popover(isPresented: $showRemovalHistory)')==1
 assert source.count('RemovalHistoryPopover(model: model)')==1
 assert '.disabled(model.lastRemoved.isEmpty)' in source[button:toolbar[1]]
 assert '@State private var showRemovalHistory = false' in source
 return host,action
oldhost,_=connection(old);host,action=connection(new)
assert oldhost=='toolbar' and host=='root'
for overflow in [False,True]:
 visible_hosts={'root'} if overflow else {'root','toolbar'}
 assert (oldhost in visible_hosts)==(not overflow)
 assert host in visible_hosts
print('PASS source-derived invariant: history attachment outside toolbar; declared lifetime model only, NOT old/new native behavior proof')
# Existing content and Put Back actions must be byte-identical to reviewed base.
view='Sources/Spacelyzer/RemovalHistoryView.swift'
prior=subprocess.run(['git','show','efa2e9fe96c0705e4315575a9147795b23841ed6:'+view],check=True,capture_output=True,text=True).stdout
assert pathlib.Path(view).read_text()==prior
print('PASS same history content and Put Back implementation unchanged')
assert all(x in new for x in ['history-transition action-delivered','history-transition state=','history-transition content-appeared','history-transition content-disappeared'])
# These observations are diagnostic only. No capture gate can read them as proof.
for f in ['scripts/v1-capture.sh','scripts/check-demo-state.py']:
 assert 'history-transition' not in pathlib.Path(f).read_text()
print('PASS action/state/content-lifecycle diagnostic labels separate from visible-content gates')
sw=os.environ.get('SWIFT_BIN','/tmp/swift-6.1.2-RELEASE-ubuntu22.04/usr/bin')+'/swiftc'
with tempfile.TemporaryDirectory() as t:
 p=pathlib.Path(t)
 code='''struct Model { let lastRemoved=[1] }
let model=Model()
var showRemovalHistory=false
let action = {
'''+action+'''
}
action()
precondition(showRemovalHistory)
print("ACTION_STATE_TRUE")
'''
 (p/'main.swift').write_text(code)
 for version in ['5','6']:
  for mode,flags in [('shipping',[]),('CI',['-D','SPZ_CI_TESTS'])]:
   subprocess.run([sw,'-swift-version',version,*flags,str(p/'main.swift'),'-o',str(p/'action')],check=True,capture_output=True,text=True)
   out=subprocess.run([str(p/'action')],check=True,capture_output=True,text=True).stdout
   assert 'ACTION_STATE_TRUE' in out
   assert ('history-transition action-delivered' in out)==(mode=='CI')
   print('PASS actual extracted action executes Swift'+version,mode,'sets same state; declared model seam, NOT full SwiftUI typecheck')
   broken=code.replace('showRemovalHistory = true','/* removed state transition */')
   (p/'mut.swift').write_text(broken)
   subprocess.run([sw,'-swift-version',version,*flags,str(p/'mut.swift'),'-o',str(p/'mut')],check=True,capture_output=True,text=True)
   failed=subprocess.run([str(p/'mut')],capture_output=True,text=True)
   assert failed.returncode!=0
   print('PASS action mutation missing state assignment rejected Swift'+version,mode)
