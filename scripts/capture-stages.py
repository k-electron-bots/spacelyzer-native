#!/usr/bin/env python3
"""Bounded dependency-aware capture stages. Diagnostic statuses never pass gates.
Persist each command's actual response before progressing, including failures.
Independent stages have no prerequisite on unrelated observations. Unsafe actions
must declare successful state prerequisites. No implicit retries.
"""
import json,pathlib,subprocess,time,os,signal,sys,importlib.util
_spec=importlib.util.spec_from_file_location("bounded",pathlib.Path(__file__).with_name("run-bounded.py"));_bounded=importlib.util.module_from_spec(_spec);_spec.loader.exec_module(_bounded)

class Stages:
 def __init__(self,output,budget):
  self.output=pathlib.Path(output);self.output.mkdir(parents=True,exist_ok=True)
  self.deadline=time.monotonic()+budget;self.records=[];self.save()
 def save(self):
  failed=[r['id'] for r in self.records if r['status'] in ['failed','timed-out']]
  blocked=[r['id'] for r in self.records if r['status']=='blocked']
  data=dict(complete=False,failed=failed,blocked=blocked,stages=self.records)
  temp=self.output/'stages.tmp';temp.write_text(json.dumps(data,indent=2));temp.replace(self.output/'stages.json')
 def run(self,name,argv,*,needs=(),timeout=4,stdout_path=None,force=False):
  if any(r['id']==name for r in self.records):raise ValueError('duplicate stage '+name)
  blockers=[x for x in needs if not any(r['id']==x and r['status']=='passed' for r in self.records)]
  record=dict(id=name,argv=list(map(str,argv)),needs=list(needs),timeoutSeconds=timeout,status='blocked' if blockers else 'running',blockedBy=blockers)
  self.records.append(record);self.save()
  if blockers:return False
  remaining=self.deadline-time.monotonic()
  if force:remaining=max(remaining,float(timeout))  # restore steps may use a little past the stage budget, never skipped
  if remaining<=0:
   record.update(status='blocked',blockedBy=['capture-deadline'],reason='original stage budget exhausted');self.save();return False
  started=time.monotonic();outpath=pathlib.Path(stdout_path) if stdout_path else self.output/(name+'-stdout.txt');errpath=self.output/(name+'-stderr.txt')
  record.update(stdout=str(outpath),stderr=str(errpath));self.save()
  proc=None
  with outpath.open('w') as out,errpath.open('w') as err:
   try:
    # Only the outer runner owns a process group. Nested wide commands
    # inherit it, so phase cancellation also kills their live descendants.
    owns_group=not bool(os.environ.get('CAPTURE_SHARED_PROCESS_GROUP'))
    child_env=dict(os.environ,CAPTURE_SHARED_PROCESS_GROUP='1')
    proc=subprocess.Popen(list(map(str,argv)),stdout=out,stderr=err,start_new_session=owns_group,env=child_env)
    rc=proc.wait(timeout=min(timeout,remaining));record.update(status='passed' if rc==0 else 'failed',returncode=rc)
   except subprocess.TimeoutExpired:record.update(status='timed-out',reason='command deadline expired')
   except Exception as e:record.update(status='failed',reason=type(e).__name__+': '+str(e))
   finally:
    if proc is not None:
     try:
      if owns_group:os.killpg(proc.pid,signal.SIGKILL)
      else:_bounded.kill_tree(proc.pid)
     except ProcessLookupError:pass
     proc.wait()
    record['durationSeconds']=time.monotonic()-started;self.save()
  return record['status']=='passed'
 def blocked(self,name,by):
  self.records.append(dict(id=name,status='blocked',blockedBy=list(by),needs=list(by),argv=[]));self.save()
 def finish(self,required):
  missing=[x for x in required if not any(r['id']==x and r['status']=='passed' for r in self.records)]
  data=json.loads((self.output/'stages.json').read_text());data.update(complete=not missing,required=list(required),unmet=missing)
  (self.output/'stages.json').write_text(json.dumps(data,indent=2));print(json.dumps(data,sort_keys=True),flush=True)
  return not missing

def wide(helper,pid,out,bound):
 out=pathlib.Path(out);s=Stages(out/'wide-stages',19)
 ax=lambda *args:[helper,pid,*args]
 # Read-only observations do not depend on presentation success.
 s.run('geometry-before',ax('geometry'),timeout=2)
 s.run('no-panel',ax('nosheet'),timeout=2)
 s.run('resize',[sys.executable,'scripts/session-resize.py',pid,'1280','800'],needs=['no-panel'],timeout=7,stdout_path=out/'history-wide-resize.txt')
 s.run('geometry-after',ax('geometry'),timeout=2)
 s.run('snapshot-after-resize',ax('snapshot'),timeout=2,stdout_path=out/'v1-snapshot-history-wide-before.txt')
 # Wide layout (run 40198570175 AX snapshot): the history button is an AXButton whose description is "Removed"
 # (the SwiftUI accessibilityLabel "Removal history" does not surface on the toolbar item). The compact layout has no
 # such direct button; it has the "more toolbar items" overflow whose menu item is also "Removed". The popover is anchored
 # to the content host, not the button, and AXPress does not depend on the item being on the display.
 direct=s.run('open-direct',ax('press','Removed'),needs=['resize'],timeout=2)
 if not direct:
  # Alternate spelling only (same control, other label), before any overflow route.
  direct=s.run('open-direct-alt',ax('press','Removal history'),needs=['resize'],timeout=2)
 if not direct:
  # Only a failed direct open with successful resize permits overflow fallback.
  s.run('open-overflow',ax('choose','more toolbar items','Removed'),needs=['resize'],timeout=3)
 opened=('open-direct' if any(r['id']=='open-direct' and r['status']=='passed' for r in s.records) else 'open-direct-alt') if direct else 'open-overflow'
 s.run('content',ax('sheettext','Backup 2025.zip'),needs=[opened],timeout=2,stdout_path=out/'history-wide-content.txt')
 s.run('snapshot-live',ax('snapshot'),timeout=2,stdout_path=out/'v1-snapshot-history-wide-live.txt')
 # A rect capture is clipped to the display (run 40098663789: a 1280-wide window gave a 992-wide image), so the
 # wide images come from per-window id captures, then the actual PNG width is judged against the observed frame.
 wins=s.run('windows',ax('windowinfo'),needs=['content'],timeout=2)
 if wins:
  try:
   rows=[tuple(int(v) for v in l.split()) for l in (s.output/'windows-stdout.txt').read_text().splitlines() if l.strip()]
   if not rows or any(len(r)!=6 or r[4]<=0 or r[5]<=0 for r in rows):raise ValueError('malformed window list')
   main=max((r for r in rows if r[1]==0),key=lambda r:r[4]*r[5],default=None)
   if main is None:raise ValueError('no layer-0 main window in list')
   others=[r for r in rows if r!=main]
   img=out/'screenshot-v1-removal-history-wide.png'
   s.run('bounds-width',[sys.executable,'scripts/session-resize.py','--bounds-width',s.output/'windows-stdout.txt',main[0],'1280'],needs=['windows'],timeout=2,stdout_path=out/'history-wide-bounds-width.txt')
   s.run('image',['screencapture','-x','-o','-l',main[0],img],needs=['content','resize','bounds-width'],timeout=3)
   s.run('image-nonempty',['test','-s',img],needs=['image'],timeout=1)
   s.run('image-width',[sys.executable,'scripts/session-resize.py','--png-width',img,'1280'],needs=['image-nonempty'],timeout=2,stdout_path=out/'history-wide-image-width.txt')
   # Run 40201792105: a window-id capture of a 1280pt window at origin x=32 on a 1024pt display had alpha=0 from x=992 on
   # (display edge 1024 minus origin 32). Each capture is judged only on the columns that WindowServer bounds say are on
   # the display (alpha > 0 and real content), and two positions must together cover the whole width. Never stitched.
   geo=s.output/'geometry-before-stdout.txt'
   pop=out/'screenshot-v1-removal-history-wide-popover.png'
   if others:
    top=max(others,key=lambda r:r[4]*r[5])
    # Run 40201792105: `screencapture -l <popover id>` returned the byte-identical 1280x677 main-window image (md5 equal), so
    # it never proved a separate popover picture. Capture the popover's own on-display rectangle instead.
    prect='%d,%d,%d,%d'%(top[2],top[3],top[4],top[5])
    s.run('popover-image',['screencapture','-x','-R',prect,pop],needs=['image'],timeout=3)
    s.run('popover-nonempty',['test','-s',pop],needs=['popover-image'],timeout=1)
    s.run('popover-width',[sys.executable,'scripts/session-resize.py','--png-width',pop,top[4]],needs=['popover-nonempty'],timeout=2,stdout_path=out/'history-wide-popover-width.txt')
    s.run('popover-colours',[sys.executable,'scripts/session-resize.py','--png-colours',pop],needs=['popover-width'],timeout=3,stdout_path=out/'history-wide-popover-colours.txt')
    # The pictures only count if the history entry was still shown when they were taken and both windows are the
    # same ones listed before the captures; a non-empty popover file alone proves neither.
    s.run('content-after',ax('sheettext','Backup 2025.zip'),needs=['popover-nonempty'],timeout=2,stdout_path=out/'history-wide-content-after.txt')
    s.run('windows-after',ax('windowinfo'),needs=['popover-nonempty'],timeout=2,stdout_path=out/'history-wide-windows-after.txt')
    s.run('bound-windows',[sys.executable,'scripts/session-resize.py','--same-windows',s.output/'windows-stdout.txt',out/'history-wide-windows-after.txt',main[0],top[0]],needs=['windows-after'],timeout=2,stdout_path=out/'history-wide-bound-windows.txt')
    # Position 2: move the window left so its right edge lands on the display (x=-256 puts a 1280pt window's right edge
    # at 1024), capture the same two things again, then move back. Every gate is repeated per position.
    sx=-256;dx=sx-main[2]
    # The window is only moved when the budget also covers the restore (move 3s + restore windowinfo/check 5s + margin).
    if s.deadline-time.monotonic()<9:s.blocked('move-left',['insufficient-budget-for-move-and-restore'])
    else:s.run('move-left',ax('move',sx,main[3]),needs=['bound-windows'],timeout=3,stdout_path=out/'history-wide-move-left.txt')
    s.run('windows-shifted',ax('windowinfo'),needs=['move-left'],timeout=2,stdout_path=out/'history-wide-windows-shifted.txt')
    s.run('shifted-origin',[sys.executable,'scripts/session-resize.py','--bounds-x',out/'history-wide-windows-shifted.txt',main[0],sx],needs=['windows-shifted'],timeout=2,stdout_path=out/'history-wide-shifted-origin.txt')
    s.run('shifted-windows',[sys.executable,'scripts/session-resize.py','--shifted-windows',s.output/'windows-stdout.txt',out/'history-wide-windows-shifted.txt',main[0],top[0],dx],needs=['shifted-origin'],timeout=2,stdout_path=out/'history-wide-shifted-windows.txt')
    s.run('content-shifted',ax('sheettext','Backup 2025.zip'),needs=['shifted-windows'],timeout=2,stdout_path=out/'history-wide-content-shifted.txt')
    simg=out/'screenshot-v1-removal-history-wide-shifted.png'
    s.run('image-shifted',['screencapture','-x','-o','-l',main[0],simg],needs=['shifted-windows'],timeout=3)
    s.run('image-shifted-nonempty',['test','-s',simg],needs=['image-shifted'],timeout=1)
    s.run('image-shifted-width',[sys.executable,'scripts/session-resize.py','--png-width',simg,'1280'],needs=['image-shifted-nonempty'],timeout=2,stdout_path=out/'history-wide-shifted-image-width.txt')
    s.run('image-range-b',[sys.executable,'scripts/session-resize.py','--png-range',simg,out/'history-wide-windows-shifted.txt',main[0],geo,s.output/'windows-stdout.txt'],needs=['image-shifted-width'],timeout=4,stdout_path=out/'history-wide-image-range-b.txt')
    s.run('image-range-a',[sys.executable,'scripts/session-resize.py','--png-range',img,s.output/'windows-stdout.txt',main[0],geo,out/'history-wide-windows-shifted.txt'],needs=['image-width','shifted-windows'],timeout=4,stdout_path=out/'history-wide-image-range-a.txt')
    s.run('coverage',[sys.executable,'scripts/session-resize.py','--coverage',s.output/'windows-stdout.txt',out/'history-wide-windows-shifted.txt',main[0],geo],needs=['image-range-a','image-range-b'],timeout=2,stdout_path=out/'history-wide-coverage.txt')
    pshift=out/'screenshot-v1-removal-history-wide-popover-shifted.png'
    srect='%d,%d,%d,%d'%(top[2]+dx,top[3],top[4],top[5])
    s.run('popover-shifted-image',['screencapture','-x','-R',srect,pshift],needs=['shifted-windows'],timeout=3)
    s.run('popover-shifted-width',[sys.executable,'scripts/session-resize.py','--png-width',pshift,top[4]],needs=['popover-shifted-image'],timeout=2,stdout_path=out/'history-wide-popover-shifted-width.txt')
    s.run('popover-shifted-colours',[sys.executable,'scripts/session-resize.py','--png-colours',pshift],needs=['popover-shifted-width'],timeout=3,stdout_path=out/'history-wide-popover-shifted-colours.txt')
    s.run('content-shifted-after',ax('sheettext','Backup 2025.zip'),needs=['popover-shifted-image'],timeout=2,stdout_path=out/'history-wide-content-shifted-after.txt')
    # Put the window back whenever a move was ATTEMPTED (passed, failed or timed out: a failed gate or a timeout can still
    # have displaced it). Only a move that never ran (blocked) needs no restore. Restore steps are forced: they run even
    # when the stage budget is spent. Completion is gated on restored-bounds (same x, y, size; popover present).
    if any(r['id']=='move-left' and r['status'] in ('passed','failed','timed-out') for r in s.records):
     s.run('move-back',ax('move',main[2],main[3]),needs=[],timeout=3,stdout_path=out/'history-wide-move-back.txt',force=True)
     s.run('windows-restored',ax('windowinfo'),needs=[],timeout=2,stdout_path=out/'history-wide-windows-restored.txt',force=True)
     s.run('restored-bounds',[sys.executable,'scripts/session-resize.py','--restored',s.output/'windows-stdout.txt',out/'history-wide-windows-restored.txt',main[0],top[0]],needs=['move-back','windows-restored'],timeout=2,stdout_path=out/'history-wide-restored-bounds.txt',force=True)
    else:s.blocked('move-back',['move-never-attempted'])
   else:s.blocked('popover-image',['no-popover-window-in-list'])
  except ValueError as e:
   s.blocked('image',['invalid-window-list']);(s.output/'windows-invalid.txt').write_text(str(e))
 else:s.blocked('image',['windows'])
 # Escape is allowed only after an open action returned success, not blind input
 # from a stage that never opened. Diagnostic snapshots remain independent.
 s.run('dismiss',ax('escape'),needs=[opened],timeout=2)
 return s.finish(['resize','content','image','image-nonempty','bounds-width','image-width','image-range-a','popover-image','popover-nonempty','popover-width','popover-colours','content-after','bound-windows','move-left','shifted-origin','shifted-windows','content-shifted','content-shifted-after','image-shifted','image-shifted-nonempty','image-shifted-width','image-range-b','coverage','popover-shifted-image','popover-shifted-width','popover-shifted-colours','move-back','restored-bounds','dismiss'])

if __name__=='__main__':
 if len(sys.argv)==6 and sys.argv[1]=='wide':sys.exit(not wide(*sys.argv[2:]))
 raise SystemExit('usage: wide HELPER PID OUT BOUND')
