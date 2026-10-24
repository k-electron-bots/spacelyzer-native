#!/usr/bin/env python3
"""Explicit observed-sheet-v1 criterion. Native accessor result stays separate.
All legacy non-identity checks run. Only step78 unknown identity can use complete
external bytes, verified against current workflow pins and exact output image.
Artifact consistency is not cryptographic proof against a compromised producer.
"""
import importlib.util,pathlib,sys,subprocess,json

def module(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
base=pathlib.Path(__file__).parent
native=module('native_check',base/'check-demo-state.py')
binding=module('sheet_binding',base/'capture-sheet-evidence.py')

def check(d,last,first,output,pin,expected_source,expected_executable,images):
 routes=[]
 def observed(step,state):
  if step!=78 or state.get('sheetId') not in ['unknown','notscanned']:raise ValueError('conflicting/missing native identity cannot use external route')
  result=binding.verify_observed_evidence(pathlib.Path(d)/'spz-demo-state-78',pathlib.Path(d)/'spz-demo-ready-78',pin,output,expected_source,expected_executable,pathlib.Path(images)/'screenshot-demo-78.png')
  routes.append(result)
 bad=native.check(d,last,first,observed_sheet=observed)
 return bad,routes
if __name__=='__main__':
 if len(sys.argv)!=9:raise SystemExit('usage: STATE LAST FIRST OUTPUT PIN EXECUTABLE IMAGES SOURCE')
 source=sys.argv[8]
 bad,routes=check(sys.argv[1],int(sys.argv[2]),int(sys.argv[3]),sys.argv[4],sys.argv[5],source,sys.argv[6],sys.argv[7])
 for route in routes:print('OBSERVED IDENTITY',json.dumps(route,sort_keys=True))
 for fail in bad:print('FIDELITY FAIL',fail)
 print('observed-sheet-v1 fidelity:', 'FAIL' if bad else 'PASS','; native accessor state remains raw, not rewritten')
 sys.exit(bool(bad))
