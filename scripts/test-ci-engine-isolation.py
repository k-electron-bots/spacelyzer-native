#!/usr/bin/env python3
"""Execute real build-ci-engine.sh with stub cargo/uname; inspect actual archive symbols.
No Rust compilation or Mac claims here. Real Rust coverage is test-ci-scan-gate.sh.
"""
import os, pathlib, shutil, subprocess, tempfile
repo=pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='spz-isolation-') as td:
    w=pathlib.Path(td);(w/'scripts').mkdir();(w/'bin').mkdir();(w/'build/lib').mkdir(parents=True)
    shutil.copy(repo/'scripts/build-ci-engine.sh',w/'scripts');shutil.copy(repo/'scripts/defined-symbols.py',w/'scripts')
    (w/'build/lib/libspacelyzer_engine.a').write_bytes(b'untouched-shipping-sentinel')
    src=w/'symbols.c';src.write_text('void spz_ci_scan_start_parked(void){}\nvoid spz_ci_scan_gate_state(void){}\nvoid spz_ci_scan_gate_release(void){}\n')
    subprocess.run(['cc','-c',str(src),'-o',str(w/'symbols.o')],check=True)
    subprocess.run(['ar','rcs',str(w/'valid.a'),str(w/'symbols.o')],check=True)
    for name,body in {
      'uname':'#!/bin/sh\necho Linux\n',
      'cargo':'''#!/bin/sh
case "$*" in *'--features ci-checks --target-dir target/ci-checks --lib'*) ;; *) exit 7;; esac
[ "${BREAK_BUILD:-}" = yes ] && exit 9
mkdir -p target/ci-checks/release
cp valid.a target/ci-checks/release/libspacelyzer_engine.a
'''
    }.items():
        p=w/'bin'/name;p.write_text(body);p.chmod(0o755)
    env=dict(os.environ,PATH=str(w/'bin')+':'+os.environ['PATH'])
    subprocess.run(['bash','scripts/build-ci-engine.sh'],cwd=w,env=env,check=True,stdout=subprocess.PIPE)
    assert (w/'build/lib/libspacelyzer_engine.a').read_bytes()==b'untouched-shipping-sentinel'
    assert (w/'build/ci-lib/libspacelyzer_ci.a').is_file()
    assert subprocess.run(['bash','scripts/build-ci-engine.sh'],cwd=w,env=dict(env,BREAK_BUILD='yes'),stdout=subprocess.PIPE,stderr=subprocess.PIPE).returncode!=0
    # nm that fails (as Apple nm did on the lipo'd archive in Mac run 39832527366): presence still proven, error printed.
    n=w/'bin'/'nm';n.write_text('#!/bin/sh\necho "nm: simulated member error" >&2\nexit 1\n');n.chmod(0o755)
    r=subprocess.run(['bash','scripts/build-ci-engine.sh'],cwd=w,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    assert r.returncode==0 and b'simulated member error' in r.stderr,r.stderr
    # ...and a CI archive lacking a required symbol still fails even with nm broken.
    (w/'src2.c').write_text('void spz_ci_scan_start_parked(void){}\n');subprocess.run(['cc','-c',str(w/'src2.c'),'-o',str(w/'s2.o')],check=True)
    subprocess.run(['rm','-f',str(w/'valid.a')]);subprocess.run(['ar','rcs',str(w/'valid.a'),str(w/'s2.o')],check=True)
    assert subprocess.run(['bash','scripts/build-ci-engine.sh'],cwd=w,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE).returncode!=0
    n.unlink()
    print('PASS actual shell: isolated paths, shipping unchanged, CI symbol definitions, build failure propagation')
pkg=(repo/'Package.swift').read_text();test=(repo/'scripts/build-test-app.sh').read_text()
assert 'ciEngine ? ["-Lbuild/ci-lib", "-lspacelyzer_ci"] : ["-Lbuild/lib", "-lspacelyzer_engine"]' in pkg
assert 'export SPZ_CI_ENGINE=1' in test and '.build-citests-rendezvous' in test
assert 'shipping_before' in test and 'shipping_after' in test
print('PASS structural package/test-build isolation checks (not Swift execution)')
