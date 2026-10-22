#!/usr/bin/env python3
"""Exact workflow source/mode matrix and executed gate bodies, not Mac evidence."""
import pathlib,yaml,re,subprocess,tempfile
repo=pathlib.Path(__file__).resolve().parent.parent
steps=yaml.safe_load((repo/'.github/workflows/ci.yml').read_text())['jobs']['macos']['steps']
def st(key):return next(s for s in steps if s.get('id')==key or s.get('name','').startswith(key))
keys=['technical_hardening','compile_only','consolidated','docs_only','perf','perf_in_run','docs_2x']
def enabled(step,**values):
 e=step.get('if','${{ true }}').strip()[3:-2].strip()
 e=e.replace('&&',' and ').replace('||',' or ').replace('always()','True')
 e=re.sub(r'!(?!=)',' not ',e);e=re.sub(r'inputs\.(\w+)',lambda m:str(values.get(m[1],False)),e)
 e=re.sub(r'steps\.(\w+)\.outcome',lambda m:repr('success'),e)
 e=re.sub(r'steps\.(\w+)\.outputs\.(\w+)',lambda m:repr(''),e)
 return eval(e,{},dict(true=True,false=False))
assert steps[0]['name'].startswith('Anchor hard35min')
tech={'technical_hardening':True}
for k in ['Build universal engine','Build Swift app','Typecheck the on-demand','testbuild','rust','failpoints','bulk','ordering','reset','ui_launch','asserts','functional_artifact','scale','scale_artifact','Technical-hardening evidence gate']:
 assert enabled(st(k),**tech),k
for k in ['Import self-signed','dmg','Capture DMG','docs']:
 assert not enabled(st(k),**tech),k
assert not enabled(st('scale')) and not enabled(st('scale'),consolidated=True)
assert enabled(st('docs'),consolidated=True) and enabled(st('dmg'),consolidated=True)
# Run exact exclusivity body with substitutions.
b=st('Validate exclusive')['run']
for k in [None]+keys[1:]:
 body=re.sub(r'\$\{\{ inputs\.(\w+) \}\}',lambda m:'true' if m[1]==k else 'false',b)
 r=subprocess.run(['bash','-eo','pipefail','-c',body],capture_output=True,text=True)
 assert (r.returncode==0)==(k is None),(k,r.stdout,r.stderr)
# Every technical gate dependency fails on failure/skipped/cancelled and names it.
gate=st('Technical-hardening evidence gate')['run']
deps=re.findall(r'steps\.(\w+)\.outcome',gate)
for bad in [None]+deps:
 for status in (['success'] if bad is None else ['failure','skipped','cancelled']):
  body=re.sub(r'\$\{\{ steps\.(\w+)\.outcome \}\}',lambda m:status if m[1]==bad else 'success',gate)
  r=subprocess.run(['bash','-eo','pipefail','-c',body],capture_output=True,text=True)
  assert (r.returncode==0)==(bad is None),(bad,status,r.stdout)
  if bad:assert bad+'='+status in r.stdout
# Demo checks/capture sequence must remain after the preamble's conditional fi.
launch=st('ui_launch')['run'];assert launch.index('          fi'.strip())<launch.index('# Scripted interaction run:')
assert 'for step in 1 2 3' in launch and '80 81;' in launch
assert 'expected=178' in st('asserts')['run'] and 'seq 1 81' in st('asserts')['run']
assert st('functional_artifact') in steps[:steps.index(st('scale'))]
assert 'fixture/' not in str(st('scale_artifact')['with']['path'])
print('PASS exact technical mode matrix, exclusivity, all gate failure states, retained178checks/81captures and artifact gates')
