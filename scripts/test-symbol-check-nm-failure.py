#!/usr/bin/env python3
"""Old-fail/new-pass regression for Mac run 39832527366: nm exits non-zero on a clean archive.
Executed on Linux with a stub nm that fails like the observed run; NOT Apple nm evidence."""
import os,pathlib,shutil,subprocess,tempfile
repo=pathlib.Path(__file__).resolve().parent.parent
old=subprocess.run(['git','show','6a7465427e83b355ba281cfbc5b8bd593423101a:scripts/check-no-ci-symbols.sh'],cwd=repo,stdout=subprocess.PIPE,check=True).stdout
with tempfile.TemporaryDirectory(prefix='nm-fail-') as td:
 w=pathlib.Path(td);(w/'bin').mkdir()
 (w/'old.sh').write_bytes(old)
 shutil.copy(repo/'scripts/check-no-ci-symbols.sh',w/'new.sh')
 for label,src in [('clean','void spz_scan_start(void){}'),('dirty','void spz_scan_start(void){}\nvoid spz_ci_scan_gate_release(void){}'),('nocontrol','void other(void){}')]:
  (w/f'{label}.c').write_text(src);subprocess.run(['cc','-c',str(w/f'{label}.c'),'-o',str(w/f'{label}.o')],check=True)
  subprocess.run(['ar','rcs',str(w/f'{label}.a'),str(w/f'{label}.o')],check=True)
 stub=w/'bin/nm';stub.write_text('#!/bin/sh\necho "nm: simulated member error" >&2\nexit 1\n');stub.chmod(0o755)
 fail=dict(os.environ,PATH=str(w/'bin')+':'+os.environ['PATH']);real=dict(os.environ)
 def run(script,f,env):return subprocess.run(['bash',str(w/script),str(w/f)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 r=run('old.sh','clean.a',fail);assert r.returncode==1 and b'cannot inspect' in r.stderr,'old script must fail on nm failure (reproduces Mac run)'
 r=run('new.sh','clean.a',fail);assert r.returncode==0,r.stderr
 assert b'nm -g exited 1' in r.stderr and b'simulated member error' in r.stderr,'nm failure must be printed, not hidden'
 r=run('new.sh','dirty.a',fail);assert r.returncode==1 and b'byte scan' in r.stderr,'dirty must fail even when nm is broken'
 r=run('new.sh','dirty.a',real);assert r.returncode==1
 r=run('new.sh','nocontrol.a',fail);assert r.returncode==1 and b'positive control' in r.stderr
 r=run('new.sh','nocontrol.a',real);assert r.returncode==1
 assert run('new.sh','clean.a',real).returncode==0
 (w/'empty.a').write_bytes(b'');assert run('new.sh','empty.a',fail).returncode==1
 assert run('new.sh','absent.a',fail).returncode==1
 (w/'text.a').write_text('not an archive');assert run('new.sh','text.a',fail).returncode==1
 print('PASS old script fails with nm failure; new passes clean, prints nm error, rejects dirty/no-control/empty/absent/garbage')
