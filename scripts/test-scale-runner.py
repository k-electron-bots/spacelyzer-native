#!/usr/bin/env python3
"""Executed scale verdict failure controls. Not a Mac/Swift/scale performance result."""
import importlib.util,pathlib,tempfile,subprocess,sys
p=pathlib.Path(__file__).with_name('run-scale-check.py')
spec=importlib.util.spec_from_file_location('runner',p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
names=['scale-real-scan-exact-million-item-tree','scale-mounted-million-row-publication','scale-filter-exact-single-file','scale-clear-filter-restores-million-rows','scale-main-queue-delay-under-250ms']
with tempfile.TemporaryDirectory() as td:
 d=pathlib.Path(td)
 def reset():
  (d/'result.txt').write_text('PASS 5 scale checks, each exactly once\n')
  (d/'assertions.txt').write_text(''.join('PASS '+n+' detail\n' for n in names))
  (d/'scale-mounted-window.png').write_bytes(b'\x89PNG\r\n\x1a\n'+b'x'*32)
  (d/'scale-metrics.txt').write_text('test stub metrics, not real scale evidence\n')
 reset();m.validate_result(d)
 for kind in ['missing','duplicate','failure','bad-header','missing-png','empty-metrics']:
  reset()
  if kind=='missing':(d/'assertions.txt').write_text(''.join('PASS '+n+'\n' for n in names[:-1]))
  if kind=='duplicate':(d/'assertions.txt').write_text(''.join('PASS '+n+'\n' for n in names+[names[0]]))
  if kind=='failure':(d/'assertions.txt').write_text((d/'assertions.txt').read_text().replace('PASS ','FAIL ',1))
  if kind=='bad-header':(d/'result.txt').write_text('PASS\n')
  if kind=='missing-png':(d/'scale-mounted-window.png').unlink()
  if kind=='empty-metrics':(d/'scale-metrics.txt').write_text('')
  try:m.validate_result(d)
  except (RuntimeError,FileNotFoundError):pass
  else:raise AssertionError('accepted '+kind)
  print('PASS refused',kind)
if sys.platform!='darwin':
 r=subprocess.run([sys.executable,str(p),'--app','/not/an/app','--work','/not/a/work','--job-deadline-epoch','0'],capture_output=True,text=True)
 assert r.returncode!=0 and 'needs macOS' in r.stderr
 print('PASS Linux refuses Mac segment execution')
# Source contract checks, not Swift compilation or execution.
repo=p.resolve().parent.parent
s=(repo/'Sources/Spacelyzer/LargeScanDriver.swift').read_text()
for fragment in ['expectedNodes: UInt64 = 1_000_005','expectedRows = 1_000_002','probe.readEvidence?()',
                 'evidence.treeID == ObjectIdentifier(tree)','evidence.filterID == filter.map(ObjectIdentifier.init)',
                 'evidence.hitValid','currentTreemap(tree, filter: model.activeFilter)',
                 'currentTreemap(tree, filter: nil)','await sampler.stopAndFlush()',
                 'measured.samples >= 10 && measured.peak < 250', 'private var stopped = false']:
 assert fragment in s,fragment
# Exact fixture counts are derived from the generator itself without creating1m files.
f=repo/'scripts/make_fixtures.py';spec=importlib.util.spec_from_file_location('fixture',f);fm=importlib.util.module_from_spec(spec);spec.loader.exec_module(fm)
count=dirs=direct=0
for rel,_,_,isdir in fm.PROFILES['expansion-1m']():
 count+=1;dirs+=int(isdir);direct+=int(rel.count('/')==1)
assert count+1==1_000_005 and dirs==2 and direct+1==1_000_002,(count,dirs,direct)
print('PASS structural probe/sampler contracts and actual generator node/row counts (no Swift/scale execution)')

assert 'workDeadline = ProcessInfo.processInfo.systemUptime + 150' in s
assert 'min(ProcessInfo.processInfo.systemUptime + seconds, workDeadline)' in s
runner=p.read_text()
assert runner.index('available < a.budget_seconds') < runner.index("w.mkdir();(w/'result').mkdir()")  # the segment workdir is made only after the budget check (early() mkdir only records a verdict)
assert 'required=True' in runner and 'artifact_reserve_seconds < 120' in runner
print('PASS structural work/finalization and whole-job artifact reserve contracts (not runtime budget evidence)')

# ---- Executed always-written verdict/log artifact controls (fake generator/app; not Mac, not scale evidence) ----
import os,signal,time,types,textwrap
def mk(td,gen_body,app_py=None):
    t=pathlib.Path(td);(t/'app/Contents/MacOS').mkdir(parents=True);g=t/'gen.py';g.write_text(textwrap.dedent(gen_body))
    ex=t/'app/Contents/MacOS/Spacelyzer'
    ex.write_text('#!'+sys.executable+'\n'+textwrap.dedent(app_py or 'import sys\nsys.exit(0)\n'));ex.chmod(0o755)
    w=t/'work';w.mkdir();(w/'result').mkdir();return t,g,w
def args(budget=215): return types.SimpleNamespace(budget_seconds=budget,available=budget+5)
def fixture_gen(extra=''): return ("import sys,os,time,pathlib\nmode,root=sys.argv[1],sys.argv[2]\nif mode=='generate':\n"
    "    pathlib.Path(root,'expansion-1000000').mkdir(parents=True)\n    pathlib.Path(root,'expansion-1000000/f0000000.dat').write_bytes(b'')\n"
    "    print('  ... 100000 entries elapsed=1.0s',flush=True)\n    "+extra+"\n")
good_app=("import os,pathlib\nR=pathlib.Path(os.environ['SPZ_RESULT_DIR'])\n(R/'result.txt').write_text('PASS 5 scale checks, each exactly once\\n')\n"
    "(R/'assertions.txt').write_text(''.join('PASS '+n+' d\\n' for n in "+repr(names)+"))\n(R/'scale-mounted-window.png').write_bytes(b'\\x89PNG\\r\\n\\x1a\\n'+b'0'*32)\n(R/'scale-metrics.txt').write_text('metrics\\n')\n")
def verdict(w): return (w/'segment-verdict.txt').read_text()
with tempfile.TemporaryDirectory() as td:
    t,g,w=mk(td,fixture_gen('pass'),good_app)
    m.segment(args(),t/'app',w,str(g),profile='x')
    v=verdict(w); assert v.startswith('PASS ') and 'phase generate: ok' in v and 'phase cleanup: ok' in v,v
    assert 'entries elapsed' in (w/'generator.log').read_text() and not (w/'fixture').exists()
    print('PASS fake end-to-end: PASS verdict, phase timings, generator log kept, fixture removed')
def cancel_case(sig, phase_name):
    with tempfile.TemporaryDirectory() as td:
        if phase_name=='generator': t,g,w=mk(td,fixture_gen('time.sleep(120)'))
        else: t,g,w=mk(td,fixture_gen('pass'),"import os,time,pathlib\npathlib.Path(os.environ['SPZ_RESULT_DIR'],'..','app.pid').resolve().write_text(str(os.getpid()))\ntime.sleep(120)\n")
        drv=t/'drv.py';drv.write_text("import importlib.util,pathlib,sys,types\nspec=importlib.util.spec_from_file_location('r','%s')\nm=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)\na=types.SimpleNamespace(budget_seconds=420,available=425)\nm.segment(a,pathlib.Path('%s/app'),pathlib.Path('%s'),'%s',profile='x')\n"%(p,t,w,g))
        pr=subprocess.Popen([sys.executable,str(drv)],stderr=subprocess.PIPE)
        if phase_name=='generator': time.sleep(3)
        else:
            for _ in range(100):
                if (w/'app.pid').exists(): break
                time.sleep(0.2)
            assert (w/'app.pid').exists(),'fake app never started'
        pr.send_signal(sig);pr.wait(timeout=30)
        v=verdict(w); assert pr.returncode!=0 and v.startswith('INCOMPLETE ') and 'cancel' in v,(pr.returncode,v)
        if phase_name=='generator': assert 'entries elapsed' in (w/'generator.log').read_text()
        else:
            pid=int((w/'app.pid').read_text())
            try: os.kill(pid,0); alive=True
            except ProcessLookupError: alive=False
            assert not alive,'leaked app child'
        print('PASS cancel (%s) mid-%s: INCOMPLETE cancelled verdict, logs kept, red, no leaked child'%(sig.name,phase_name))
for _s in (signal.SIGTERM, signal.SIGINT):
    for _ph in ('generator','app'): cancel_case(_s,_ph)
# early precondition failure still leaves a verdict artifact (non-Mac host stands in for any precondition failure)
if sys.platform!='darwin':
    with tempfile.TemporaryDirectory() as td:
        rt=pathlib.Path(td)/'rt';rt.mkdir();w=rt/'spz-scale'
        r=subprocess.run([sys.executable,str(p),'--app','/not/app','--work',str(w),'--job-deadline-epoch','0'],capture_output=True,text=True,env=dict(os.environ,RUNNER_TEMP=str(rt)))
        assert r.returncode!=0 and (w/'segment-verdict.txt').read_text().startswith('NOT-RUN'),(r.returncode,r.stderr)
        print('PASS early precondition failure leaves a NOT-RUN verdict artifact and stays red')
