#!/usr/bin/env python3
"""Fault-inject real stage subprocesses and actual v1 path. No native claim."""
import importlib.util,pathlib,tempfile,sys,json,time,os
s=importlib.util.spec_from_file_location('stage','scripts/capture-stages.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
with tempfile.TemporaryDirectory() as t:
 p=pathlib.Path(t);r=m.Stages(p,3)
 assert not r.run('A',[sys.executable,'-c','print("AXWindows error -25204");raise SystemExit(7)'])
 assert r.run('independent-B',[sys.executable,'-c','print("B actual response")'])
 assert not r.run('unsafe-dependent',[sys.executable,'-c','raise Exception("MUST NOT EXECUTE")'],needs=['A'])
 assert not r.run('independent-C',[sys.executable,'-c','import sys;print("resize requested1280x800 observed1280x625",file=sys.stderr);raise SystemExit(8)'])
 assert not r.finish(['A','independent-B','unsafe-dependent','independent-C'])
 d=json.loads((p/'stages.json').read_text());assert d['failed']==['A','independent-C'] and d['blocked']==['unsafe-dependent']
 assert 'AXWindows' in (p/'A-stdout.txt').read_text() and 'observed1280x625' in (p/'independent-C-stderr.txt').read_text()
 assert not (p/'unsafe-dependent-stdout.txt').exists()
 print('PASS actual multi-failure: independentB/C run after A; unsafe dependent blocked with cause; actual responses+aggregate retained')
with tempfile.TemporaryDirectory() as t:
 p=pathlib.Path(t);r=m.Stages(p,2)
 assert not r.run('timeout',[sys.executable,'-u','-c','import time;print("before blocked AX call");time.sleep(10)'],timeout=.1)
 assert r.run('independent-after-timeout',[sys.executable,'-c','print("still executes")'],timeout=.5)
 assert not r.finish(['timeout','independent-after-timeout'])
 assert 'before blocked' in (p/'timeout-stdout.txt').read_text()
 assert json.loads((p/'stages.json').read_text())['stages'][0]['status']=='timed-out'
 print('PASS actual timeout partial stdout retained; independent next stage executed; final red')
with tempfile.TemporaryDirectory() as t:
 p=pathlib.Path(t);r=m.Stages(p,0)
 assert not r.run('expired',[sys.executable,'-c','print("must not run")'])
 assert not r.finish(['expired']);assert not (p/'expired-stdout.txt').exists()
 print('PASS exhausted original budget blocks rather than fake executes')

with tempfile.TemporaryDirectory() as t:
 p=pathlib.Path(t);r=m.Stages(p/'outer',3)
 nested=p/'nested.py'
 nested.write_text('import importlib.util,pathlib,sys\ns=importlib.util.spec_from_file_location("stage",sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)\nr=m.Stages(pathlib.Path(sys.argv[2])/"inner",5)\nr.run("inner",[sys.executable,"-c","import time,pathlib,sys;print(\\"inner started\\",flush=True);time.sleep(0.7);pathlib.Path(sys.argv[1]).write_text(\\"escaped\\")",sys.argv[3]],timeout=3)\n')
 assert not r.run('phase-timeout',[sys.executable,nested,pathlib.Path('scripts/capture-stages.py').resolve(),p,p/'escaped'],timeout=.4)
 assert r.records[0]['status']=='timed-out'
 assert 'inner started' in (p/'inner'/'inner-stdout.txt').read_text()
 time.sleep(.8)
 assert not (p/'escaped').exists(),'nested command escaped outer phase process-group cancellation'
 assert r.run('next-independent-phase',[sys.executable,'-c','print("no interference")'])
 print('PASS nested real stage descendant killed by phase timeout before next independent phase')

with tempfile.TemporaryDirectory() as t:
 p=pathlib.Path(t)
 for shared in [False,True]:
  marker=p/str(shared)
  code='import subprocess,sys,time,pathlib;p=subprocess.Popen([sys.executable,"-c","import time,pathlib,sys;print(\\"grandchild live\\",flush=True);time.sleep(.8);pathlib.Path(sys.argv[1]).write_text(\\"escaped\\")",sys.argv[1]]);pathlib.Path(sys.argv[1]+".pid").write_text(str(p.pid));time.sleep(10)'
  env=dict(os.environ)
  if shared:env['CAPTURE_SHARED_PROCESS_GROUP']='1'
  proc=__import__('subprocess').run([sys.executable,'scripts/run-bounded.py','.3',sys.executable,'-u','-c',code,str(marker)],env=env,capture_output=True,text=True)
  assert proc.returncode==124 and 'grandchild live' in proc.stdout,(proc.returncode,proc.stderr)
  childpid=int(pathlib.Path(str(marker)+'.pid').read_text())
  observed=__import__('subprocess').run(['ps','-o','stat=','-p',str(childpid)],capture_output=True,text=True).stdout.strip()
  assert not observed or observed.startswith('Z'),('live descendant before nextphase',observed)
  time.sleep(.8)
  assert not marker.exists(),'bounded grandchild escaped before next phase'
 print('PASS bounded realgrandchild terminated before nextphase in isolated and shared groups; partial stdout retained/rc124')
