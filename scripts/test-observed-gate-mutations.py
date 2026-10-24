#!/usr/bin/env python3
"""Run real hostile gate suite against targeted production check removals.
A mutation is caught only when the real suite fails, not a source assertion.
"""
import pathlib,tempfile,subprocess,sys,shutil
src=pathlib.Path('scripts/capture-sheet-evidence.py').read_text()
mutations={
 'exact-headline-qualifier':"    if 'Not scanned' not in texts or 'These locations were not scanned, so they are not in the totals.' not in texts:raise ValueError('missing exact observed identity text')",
 'observed-rows':"    if type(probe.get('rows')) is not int or probe['rows']<1:raise ValueError('missing loaded AX rows')",
 'scope-completeness':"    if probe.get('scopeCount')!=1 or probe.get('reason')!='observed':raise ValueError('incomplete/ambiguous external scope')",
 'observed-identity-status':"    if probe.get('identity')!='notscanned' or probe.get('complete') is not True or probe.get('source')!='external-AXUIElement':raise ValueError('external identity incomplete/refused')",
 'contradictory-observed-text':"    if any(t.startswith('Moved ') and 'to the Trash.' in t for t in texts):raise ValueError('conflicting observed removal identity')",
 'summary-native-accessor-status':"    if manifest.get('reconciliation')!=verdict:raise ValueError('summary disagrees with observed bytes')",
 'supervisor-completed':"    if supervisor.get('status')!='complete' or supervisor.get('returncode')!=0 or supervisor.get('budgetSeconds')!=18:raise ValueError('incomplete supervisor')",
 'single-attempt':"    if len(attempts)!=1:raise ValueError('missing/repeated supervisor attempt')",
 'prepost-records':"    if not isinstance(checks,list) or len(checks)!=3:raise ValueError('missing pre/post observations')",
 'prepost-process-state':"        if obs.get('phase')!=phase or obs.get('process')!={k:pin[k] for k in ['pid','start','executable']} or obs.get('source')!=expected_source or obs.get('ack') is not False or obs.get('raw_sha256')!=expected['raw_sha256'] or obs.get('ready_sha256')!=digest(root/'ready.json'):raise ValueError('pre/post observation mismatch')",
 'prepost-order':"        if type(stamp) not in [int,float] or not __import__('math').isfinite(stamp) or stamp<previous:raise ValueError('invalid observation chronology')",
 'capture-deadline':"    if checks[-1]['monotonic']-checks[0]['monotonic']>18:raise ValueError('capture binding exceeded deadline')",
 'exact-accepted-image':"    if canonical_image is not None and digest(canonical_image)!=manifest['image_sha256']:raise ValueError('accepted image differs from bound capture')",
 'artifact-byte-hashes':"        if not (bound/name).stat().st_size or digest(bound/name)!=manifest.get(field):raise ValueError('missing/tampered '+name)",
 'external-process-token-step':"    if any(probe.get(k)!=v for k,v in dict(pid=pin['pid'],step=78,captureToken=token).items()):raise ValueError('external anchor mismatch')",
 'producer-copy':"    if (root/'producer-ready.txt').read_bytes()!=producer_ready.read_bytes():raise ValueError('producer publication mismatch')",
}
for name,line in mutations.items():
 assert src.count(line)==1,(name,src.count(line))
 with tempfile.TemporaryDirectory() as t:
  p=pathlib.Path(t);(p/'scripts').mkdir()
  for f in ['check-demo-state.py','check-observed-demo-state.py','test-observed-demo-state.py']:
   shutil.copyfile(pathlib.Path('scripts')/f,p/'scripts'/f)
  indent=line[:len(line)-len(line.lstrip())]
  (p/'scripts'/'capture-sheet-evidence.py').write_text(src.replace(line,indent+'pass # deliberate mutation'))
  r=subprocess.run([sys.executable,'scripts/test-observed-demo-state.py'],cwd=p,capture_output=True,text=True)
  if r.returncode==0:raise AssertionError('mutation survived '+name)
  # Must be a hostile-case assertion failure, not an import/syntax/tool error.
  assert 'AssertionError' in r.stderr and ('SyntaxError' not in r.stderr), (name,r.stderr)
  print('PASS real hostile suite catches removed production check:',name)
