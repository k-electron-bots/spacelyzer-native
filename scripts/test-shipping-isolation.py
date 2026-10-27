#!/usr/bin/env python3
"""Executed shell/env and real-nm regressions; no Mac/Swift execution claim."""
import os,pathlib,shutil,subprocess,tempfile
root=subprocess.run(['rustc','--print','sysroot'],stdout=subprocess.PIPE).stdout.decode().strip()
host=[l.split()[1] for l in subprocess.run(['rustc','-vV'],stdout=subprocess.PIPE).stdout.decode().splitlines() if l.startswith('host:')][0]
LLVM_NM=root+'/lib/rustlib/'+host+'/bin/llvm-nm'  # Linux-hosted llvm-nm, ELF fixtures
repo=pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='shipping-env-') as td:
 w=pathlib.Path(td);(w/'scripts').mkdir();(w/'bin').mkdir();(w/'build/lib').mkdir(parents=True);(w/'normal').mkdir()
 for s in ['shipping-swift.sh','check-no-ci-symbols.sh','dump-symbols.sh']:shutil.copy(repo/'scripts'/s,w/'scripts')
 for label,source in [('clean','void spz_scan_start(void){}'),('dirty','void spz_scan_start(void){}\nvoid spz_ci_scan_start_parked(void){}')]:
  (w/f'{label}.c').write_text(source)
  subprocess.run(['cc','-c',str(w/f'{label}.c'),'-o',str(w/f'{label}.o')],check=True)
 shutil.copy(w/'clean.o',w/'build/lib/libspacelyzer_engine.a');shutil.copy(w/'clean.o',w/'normal/Spacelyzer')
 (w/'bin/swift').write_text('''#!/bin/sh
[ "${SPZ_CI_ENGINE:-}" != 1 ] || exit 77
case " $* " in *' --show-bin-path '*) printf '%s/normal\n' "$PWD";; *) echo invoked >> calls;; esac
''');(w/'bin/swift').chmod(0o755)
 env=dict(os.environ,PATH=str(w/'bin')+':'+os.environ['PATH'],SPZ_CI_ENGINE='1',SPZ_EXPECT_ARCHS='',SPZ_LLVM_NM=os.environ.get('SPZ_LLVM_NM') or LLVM_NM)
 # Old direct Swift build fails with the same ambient value and stub contract.
 assert subprocess.run(['swift','build','-c','release'],cwd=w,env=env).returncode==77
 def call():return subprocess.run(['bash','scripts/shipping-swift.sh','-c','release'],cwd=w,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 assert call().returncode==0
 for target in ['build/lib/libspacelyzer_engine.a','normal/Spacelyzer']:
  shutil.copy(w/'dirty.o',w/target);assert call().returncode!=0;shutil.copy(w/'clean.o',w/target)
 (w/'build/lib/libspacelyzer_engine.a').write_text('not an archive');assert call().returncode!=0
 print('PASS old ambient route fails; shipping wrapper clears inherited selector; LLVM nm rejects dirty archive/binary and unreadable artifact')
for file in ['scripts/package-dmg.sh','scripts/local-mac-check.sh','.github/workflows/ci.yml']:
 s=(repo/file).read_text()
 if file.endswith('local-mac-check.sh'):s=s[s.index('swift_normal()'):s.index('step swift-build-tests')]
 assert 'swift build' not in s,file
 assert 'scripts/shipping-swift.sh' in s,file
print('PASS structural coverage of shipping build entrypoints (not Mac compilation)')
