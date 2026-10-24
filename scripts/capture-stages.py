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
 def run(self,name,argv,*,needs=(),timeout=4,stdout_path=None):
  if any(r['id']==name for r in self.records):raise ValueError('duplicate stage '+name)
  blockers=[x for x in needs if not any(r['id']==x and r['status']=='passed' for r in self.records)]
  record=dict(id=name,argv=list(map(str,argv)),needs=list(needs),timeoutSeconds=timeout,status='blocked' if blockers else 'running',blockedBy=blockers)
  self.records.append(record);self.save()
  if blockers:return False
  remaining=self.deadline-time.monotonic()
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
 s.run('resize',ax('resize','1280','800'),needs=['no-panel'],timeout=3,stdout_path=out/'history-wide-resize.txt')
 s.run('geometry-after',ax('geometry'),timeout=2)
 s.run('snapshot-after-resize',ax('snapshot'),timeout=2,stdout_path=out/'v1-snapshot-history-wide-before.txt')
 direct=s.run('open-direct',ax('press','Removal history'),needs=['resize'],timeout=2)
 if not direct:
  # Only a failed direct open with successful resize permits overflow fallback.
  s.run('open-overflow',ax('choose','more toolbar items','Removed'),needs=['resize'],timeout=3)
 opened='open-direct' if direct else 'open-overflow'
 s.run('content',ax('sheettext','Backup 2025.zip'),needs=[opened],timeout=2,stdout_path=out/'history-wide-content.txt')
 s.run('snapshot-live',ax('snapshot'),timeout=2,stdout_path=out/'v1-snapshot-history-wide-live.txt')
 rect=s.run('capture-rect',ax('rect'),needs=['content'],timeout=2)
 if rect:
  try:
   values=(s.output/'capture-rect-stdout.txt').read_text().strip().split(',')
   if len(values)!=4 or any(not x.lstrip('-').isdigit() for x in values) or any(int(x)<=0 for x in values[2:]):raise ValueError('malformed capture rectangle')
   s.run('image',['screencapture','-x','-R',','.join(values),out/'screenshot-v1-removal-history-wide.png'],needs=['content','resize'],timeout=2)
   s.run('image-nonempty',['test','-s',out/'screenshot-v1-removal-history-wide.png'],needs=['image'],timeout=1)
  except ValueError as e:
   s.blocked('image',['invalid-capture-rectangle']);(s.output/'capture-rect-invalid.txt').write_text(str(e))
 else:s.blocked('image',['capture-rect'])
 # Escape is allowed only after an open action returned success, not blind input
 # from a stage that never opened. Diagnostic snapshots remain independent.
 s.run('dismiss',ax('escape'),needs=[opened],timeout=2)
 return s.finish(['resize','content','image','image-nonempty','dismiss'])

if __name__=='__main__':
 if len(sys.argv)==6 and sys.argv[1]=='wide':sys.exit(not wide(*sys.argv[2:]))
 raise SystemExit('usage: wide HELPER PID OUT BOUND')
