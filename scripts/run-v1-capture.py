#!/usr/bin/env python3
"""Independent exclusions/duplicates/cleanup/FDA phases share one preparation, not failure fate.
All use the same disposable fixture; each launches a fresh app. No production
mutation occurs after failed confirmation. Capture-only wide shares cleanup PID.
"""
import importlib.util,pathlib,os,sys,time,json,subprocess
s=importlib.util.spec_from_file_location('stages',pathlib.Path(__file__).parent/'capture-stages.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
def run(app,output):
 out=pathlib.Path(output);out.mkdir(parents=True,exist_ok=True)
 if any(out.iterdir()):raise ValueError('v1 output must be fresh; refuse stale artifacts')
 budget=float(os.environ.get('V1_BUDGET','165'));start=time.time();os.environ['V1_STARTED']=str(int(start))
 stages=m.Stages(out/'phase-stages',max(0,budget))
 # Prepare once; its failure blocks all app-driven stages. Independent phases
 # are not chained together. A failed/timeout explore cannot hide cleanup/FDA.
 for phase in ['prepare','exclusions','duplicates','cleanup','fda']:
  command=['env','V1_PHASE='+phase,'bash','scripts/v1-capture-phase.sh',app,str(out)]
  stages.run(phase,command,needs=[] if phase=='prepare' else ['prepare'],timeout={'prepare':15,'exclusions':22,'duplicates':35,'cleanup':65,'fda':25}[phase])
 stages.finish(['prepare','exclusions','duplicates','cleanup','fda'])
 status=''
 for phase in ['prepare','exclusions','duplicates','cleanup','fda']:
  p=out/('v1-phase-'+phase+'-status.txt')
  if p.exists():status+=p.read_text()
 summary=json.loads((out/'phase-stages'/'stages.json').read_text())
 for record in summary['stages']:
  if record['status']!='passed':status+='STEP-FAIL phase-'+record['id']+': '+json.dumps(record,sort_keys=True)+'\n'
 # Explicit expected end states. Missing dependent states are BLOCKED, never
 # reported as executed. Their phase's retained exact action logs are causal.
 endstates={}
 owners={'exclusions':'exclusions','duplicates':'duplicates','trash-confirm':'cleanup','trash-done':'cleanup','removal-history':'cleanup','removal-history-wide':'cleanup','fda-banner':'fda'}
 for name,phase in owners.items():
  image=out/('screenshot-v1-'+name+'.png')
  phase_record=next(r for r in summary['stages'] if r['id']==phase)
  wide_ok=True
  if name=='removal-history-wide':
   try:
    ws={x['id']:x['status'] for x in json.loads((out/'wide-stages'/'stages.json').read_text())['stages']};wide_ok=all(ws.get(k)=='passed' for k in ['resize','bounds-width','image-width','image-content','popover-nonempty','content-after','bound-windows'])
   except Exception:wide_ok=False
  if image.exists() and image.stat().st_size>0 and wide_ok:endstates[name]=dict(status='captured-unreviewed',artifact=str(image),phase=phase)
  else:endstates[name]=dict(status='blocked',blockedBy=[phase],phaseStatus=phase_record['status'],reason='required visible end state not captured',causalFailures=[x for x in (out/('v1-phase-'+phase+'-status.txt')).read_text().splitlines() if x.startswith(('FAIL','STEP-FAIL','SKIPPED'))] if (out/('v1-phase-'+phase+'-status.txt')).exists() else [phase_record.get('reason','phase not executed or timed out')])
 summary['endstates']=endstates;(out/'phase-stages'/'stages.json').write_text(json.dumps(summary,indent=2))
 original=['exclusions','duplicates','trash-confirm','trash-done','removal-history','fda-banner']
 oks=sum((out/('screenshot-v1-'+x+'.png')).exists() and (out/('screenshot-v1-'+x+'.png')).stat().st_size>0 for x in original)
 failed=any(x.startswith(('FAIL','STEP-FAIL','SKIPPED','FDA-LAYOUT FAIL','FDA-LAYOUT UNKNOWN')) for x in status.splitlines())
 passed=summary['complete'] and oks==6 and not failed and 'FDA-LAYOUT OK' in status and 'WIDE-HISTORY OK:' in status and endstates['removal-history-wide']['status']=='captured-unreviewed'
 summary['complete']=passed
 summary['acceptance']=dict(originalImages=oks,requiredOriginalImages=6,statusFailures=failed,fdaLayoutOK='FDA-LAYOUT OK' in status,wideHistoryOK='WIDE-HISTORY OK:' in status)
 (out/'phase-stages'/'stages.json').write_text(json.dumps(summary,indent=2))
 wide_state=endstates['removal-history-wide']['status']
 if passed: status+='V1-CAPTURE COMPLETE: 7 of 7 required end states (6 original shots + same-session wide history) and FDA-LAYOUT OK; pixels still need review before any publication\n'
 else:
  missing=[n for n,v in endstates.items() if v['status']!='captured-unreviewed']
  status+=f"V1-CAPTURE INCOMPLETE: required end states captured {sum(v['status']=='captured-unreviewed' for v in endstates.values())} of {len(endstates)}; the 6 original shots ({oks} captured) do NOT include the wide history shot; NOT captured: {', '.join(missing) or 'none (see status failures)'}; wide-history={wide_state}; stage summary records every failure/blocker\n"
 (out/'v1-capture-status.txt').write_text(status);print(status,flush=True)
 return 0 if passed else 1
if __name__=='__main__':sys.exit(run(*sys.argv[1:]))
