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
 r=subprocess.run([sys.executable,str(p),'--app','/not/an/app','--work','/not/a/work'],capture_output=True,text=True)
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
