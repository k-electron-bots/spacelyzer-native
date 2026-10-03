#!/usr/bin/env python3
# Unrun calibration-only proposal, not a benchmark result.
import os,sys,subprocess,tempfile,pathlib,json,time,hashlib,shutil,signal,statistics
assert sys.platform=='darwin' and os.geteuid()!=0, 'non-root Mac required'
assert len(sys.argv)==5, 'calibrator executable +three reviewed app paths'
cal=pathlib.Path(sys.argv[1]).resolve();launcher=cal.with_name('spz-launch-identity');apps=[pathlib.Path(p).resolve() for p in sys.argv[2:]]
assert all(a.name=='Spacelyzer.app' and (a/'Contents/MacOS/Spacelyzer').is_file() for a in apps)
root=pathlib.Path(tempfile.mkdtemp(prefix='spz-calibration-'));outputs=[]
evidence=pathlib.Path.cwd()/('spz-calibration-evidence-'+time.strftime('%Y%m%dT%H%M%SZ',time.gmtime()))
evidence.mkdir(exist_ok=False)
def command_output(args):
 try:return subprocess.run(args,capture_output=True,text=True,timeout=15).stdout
 except Exception as e:return f'UNAVAILABLE: {e}'
metadata=dict(swvers=command_output(['sw_vers']),arch=command_output(['uname','-m']),swift=command_output(['swift','--version']),display=command_output(['system_profiler','SPDisplaysDataType','-json']),responsibleAXHost='caller process and launcher chain require CI record; not inferred from child trusted status',calibratorHash=hashlib.sha256(cal.read_bytes()).hexdigest(),appBinaryHashes=[hashlib.sha256((a/'Contents/MacOS/Spacelyzer').read_bytes()).hexdigest() for a in apps],fixedOrder=True,persistenceFlag='requested only; equality not proof of ignored state')
(evidence/'metadata.json').write_text(json.dumps(metadata,indent=2))
def ps_exact(app):
 executable=str((app/'Contents/MacOS/Spacelyzer').resolve())
 result=subprocess.run(['/bin/ps','-axo','pid=,comm='],capture_output=True,text=True,timeout=5,check=True)
 found=[];evidence_lines=[]
 for line in result.stdout.splitlines():
  parts=line.strip().split(None,1)
  if len(parts)!=2:continue
  raw=parts[1].strip();resolved=str(pathlib.Path(raw).resolve())
  if pathlib.Path(raw).name=='Spacelyzer':evidence_lines.append(dict(pid=int(parts[0]),rawComm=raw,resolvedComm=resolved,exactMatch=resolved==executable))
  if resolved==executable:found.append(int(parts[0]))
 return dict(executable=executable,pids=found,route='ps realpath exact whole comm field',spacelyzerLinesEvidenceOnly=evidence_lines)
def manifest(folder):
 return hashlib.sha256('\n'.join(f'{p.name}:{p.stat().st_size}:{p.stat().st_blocks}' for p in sorted(folder.iterdir())).encode()).hexdigest()
try:
 for n in [200,2000]:
  fixture=root/f'flat-{n}';fixture.mkdir()
  for i in range(n):(fixture/f'{"keep-tag" if i%2==0 else "drop-tag"}-{i:06}.txt').write_bytes(b'x'*4096)
  expected_manifest=manifest(fixture)
  # Calibration of every arm in ascending order. Not timing/order-effect claims.
  for arm,app in enumerate(apps):
   assert manifest(fixture)==expected_manifest
   with open(evidence/f'arm-{arm}-{n}.app-stderr','wb') as err:
    launch=None;cleanup=[]
    before_ps=ps_exact(app)
    (evidence/f'arm-{arm}-{n}.before-ps.json').write_text(json.dumps(before_ps))
    snapshot_before=subprocess.run([str(launcher),str(app),'--snapshot'],capture_output=True,text=True,timeout=5,check=True)
    before=json.loads(snapshot_before.stdout)
    (evidence/f'arm-{arm}-{n}.before.json').write_text(json.dumps(before))
    try:
     try:
      launched=subprocess.run([str(launcher),str(app),str(fixture)],capture_output=True,text=True,timeout=40)
     except subprocess.TimeoutExpired as error:
      for channel in ['stdout','stderr']:
       value=getattr(error,channel,None)
       if isinstance(value,bytes):value=value.decode(errors='replace')
       (evidence/f'arm-{arm}-{n}.launch-timeout-{channel}').write_text(value if value is not None else 'PARTIAL OUTPUT UNAVAILABLE')
      # Independent fresh lookup process, bounded5s, same exact resolved path.
      try:
       snapshot_after=subprocess.run([str(launcher),str(app),'--snapshot'],capture_output=True,text=True,timeout=5,check=True)
       after=json.loads(snapshot_after.stdout)
       (evidence/f'arm-{arm}-{n}.after-timeout.json').write_text(json.dumps(after))
       if after['exactBundlePath'] != before['exactBundlePath']:raise RuntimeError('Snapshot path mismatch')
       cleanup=list(set(after['matchingPIDs'])-set(before['matchingPIDs']))
      except Exception as lookup_error:
       (evidence/f'arm-{arm}-{n}.quiescence-unknown.json').write_text(json.dumps(dict(reason=str(lookup_error),abortWholeJob=True,guessKills=False)))
      raise
     (evidence/f'arm-{arm}-{n}.launch-stdout').write_text(launched.stdout)
     (evidence/f'arm-{arm}-{n}.launch-stderr').write_text(launched.stderr)
     launch=json.loads(launched.stdout)
     cleanup=[int(p) for p in launch['matchingNewPIDs']]
     if launched.returncode:raise RuntimeError(f"Launch {launch['state']} exit{launched.returncode}")
     pid=int(launch['pid'])
     try:
      r=subprocess.run([str(cal),str(pid),str(n)],capture_output=True,text=True,timeout=110)
     except subprocess.TimeoutExpired as timeout:
      for channel in ['stdout','stderr']:
       value=getattr(timeout,channel,None)
       if isinstance(value,bytes):value=value.decode(errors='replace')
       (evidence/f'arm-{arm}-{n}.{channel}').write_text(value if value is not None else 'PARTIAL OUTPUT UNAVAILABLE')
      raise
     (evidence/f'arm-{arm}-{n}.stdout').write_text(r.stdout);(evidence/f'arm-{arm}-{n}.stderr').write_text(r.stderr)
     if r.returncode:
      state='BLOCKED_PERMISSION' if r.returncode==3 else f'CALIBRATION_EXIT_{r.returncode}'
      (evidence/'failure.json').write_text(json.dumps(dict(state=state,arm=arm,n=n,exit=r.returncode)))
      raise RuntimeError(state)
     out=json.loads(r.stdout);out.update(arm=arm,manifest=expected_manifest)
     assert out['rows']==n and manifest(fixture)==expected_manifest
     outputs.append(out)
    finally:
     # Always independent ps lookup, including malformed/missing launch JSON.
     try:
      after_ps=ps_exact(app)
      (evidence/f'arm-{arm}-{n}.after-ps.json').write_text(json.dumps(after_ps))
      if after_ps['executable']!=before_ps['executable']:raise RuntimeError('ps exactpath changed')
      cleanup=list(set(cleanup).union(set(after_ps['pids'])-set(before_ps['pids'])))
     except Exception as error:
      (evidence/f'arm-{arm}-{n}.ps-quiescence-unknown.json').write_text(json.dumps(dict(reason=str(error),abortWholeJob=True)))
      raise
     cleanup_results=[]
     for exact_pid in cleanup:
      outcome={'pid':exact_pid,'scope':'new exact-bundle match'}
      try:os.kill(exact_pid,signal.SIGTERM)
      except ProcessLookupError:outcome['term']='already-gone'
      deadline=time.monotonic()+5
      while time.monotonic()<deadline:
       try:os.kill(exact_pid,0)
       except ProcessLookupError:break
       time.sleep(.25)
      try:
       os.kill(exact_pid,0);os.kill(exact_pid,signal.SIGKILL);outcome['kill']='sent-after5s'
      except ProcessLookupError:outcome['kill']='not-needed'
      deadline=time.monotonic()+5
      while time.monotonic()<deadline:
       try:os.kill(exact_pid,0)
       except ProcessLookupError:break
       time.sleep(.25)
      try:os.kill(exact_pid,0);outcome['confirmedGone']=False
      except ProcessLookupError:outcome['confirmedGone']=True
      cleanup_results.append(outcome)
     (evidence/f'arm-{arm}-{n}.cleanup.json').write_text(json.dumps(cleanup_results))
     final_ps=ps_exact(app)
     (evidence/f'arm-{arm}-{n}.final-ps.json').write_text(json.dumps(final_ps))
     if any(not r['confirmedGone'] for r in cleanup_results) or set(final_ps['pids'])-set(before_ps['pids']):raise RuntimeError('Exact-bundle cleanup not confirmed; no next arm')
 # Preserve all raw values and summaries BEFORE any quality gates.
 for out in outputs:
  out['querySummaries']={}
  for key,values in out['samples'].items():
   ordered=sorted(values);warm=values[1:]
   out['querySummaries'][key]=dict(firstTouchMs=values[0],p50Ms=statistics.median(values),p95Ms=ordered[94],p99Ms=ordered[98],maxMs=max(values),warmMaxMs=max(warm),samples=len(values))
 (evidence/'raw-and-summary.json').write_text(json.dumps(outputs,indent=2))
 gates=[]
 def gate(name,passed,detail):gates.append(dict(name=name,passed=bool(passed),detail=detail))
 reference=outputs[0]
 gate('window-size-equality',all(o['size']==reference['size'] for o in outputs),'position recorded only; persistence request not proven')
 for n in [200,2000]:
  identities=[o['firstIdentities'] for o in outputs if o['rows']==n]
  gate(f'first-identities-{n}',all(v==identities[0] for v in identities),'first3 identities, no inferred root inclusion')
 for key in ['countMs','emptySelectionAttributeMs','heldRowIdentityMs','fieldMs']:
  for arm in range(3):
   small=next(o for o in outputs if o['arm']==arm and o['rows']==200)['samples'][key]
   large=next(o for o in outputs if o['arm']==arm and o['rows']==2000)['samples'][key]
   gate(f'{key}-arm{arm}-warm',max(small[1:]+large[1:])<=5 and statistics.median(large[1:])-statistics.median(small[1:])<=1,'provisional warm max5ms/scalingmedian1ms')
   gate(f'{key}-arm{arm}-first',max(small[0],large[0])<=20,'first-touch separate max20ms')
 (evidence/'gates.json').write_text(json.dumps(gates,indent=2))
 (evidence/'outcome.json').write_text(json.dumps(dict(outcome='CALIBRATION_GATES_PASS' if all(g['passed'] for g in gates) else 'CALIBRATION_GATES_FAIL',timingAllowed=False)))
 if not all(g['passed'] for g in gates):raise RuntimeError('Calibration gates failed; all gate results preserved')
 print(json.dumps(dict(driverHash=hashlib.sha256(cal.read_bytes()).hexdigest(),outputs=outputs,timingAllowed=False,remaining='selected-change input calibration +footer/denial readback +window fresh-default isolation unresolved')))
except Exception as error:
 (evidence/'failure-detail.json').write_text(json.dumps(dict(outcome='BLOCKED_OR_FAILED',reason=str(error),timingAllowed=False)))
 raise
finally:
 # Preserve an original failure if scratch cleanup also fails.
 try:shutil.rmtree(root)
 except Exception as cleanup_error:print(f'cleanup warning: {cleanup_error}',file=sys.stderr)
