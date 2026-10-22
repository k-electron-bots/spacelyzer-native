#!/usr/bin/env python3
"""verify() keeps full inventory assurance after the progress/timing change (Linux only, not Mac evidence).
Controls on a real expansion-10k fixture: healthy passes and prints phase/progress lines with elapsed; every tamper fails."""
import os, shutil, subprocess, sys, tempfile
G = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'make_fixtures.py')
fails = []
def ck(n, ok, d=''):
    print(('ok   ' if ok else 'FAIL ') + n + ('' if ok else ' :: ' + d)); (ok or fails.append(n))
def run(*a):
    r = subprocess.run([sys.executable, G, *a], capture_output=True, text=True); return r.returncode, r.stdout + r.stderr
td = tempfile.mkdtemp()
try:
    root = td + '/fx'
    rc, out = run('generate', root, '--profile', 'expansion-10k'); ck('generate 10k', rc == 0, out[-200:])
    rc, out = run('verify', root, '--profile', 'expansion-10k')
    ck('healthy verify OK with spec hash', rc == 0 and 'verify=OK' in out and 'spec_sha256=' in out, out[-300:])
    ck('progress/phase lines with elapsed', all(x in out for x in ('spec built', 'walk done', 'compared')) and 'elapsed=' in out.split('verify=OK')[-1], out[-400:])
    d = root + '/expansion-10000'; f = d + '/f0000005.dat'; st = os.lstat(f); dst = os.lstat(d)   # entry add/remove changes the directory mtime, which verify also checks
    def case(name, mutate, restore):
        mutate(); rc, out = run('verify', root, '--profile', 'expansion-10k'); restore(); os.utime(d, ns=(dst.st_atime_ns, dst.st_mtime_ns))
        ck(f'tamper fails: {name}', rc != 0 and 'verify=FAILED' in out, out[-200:])
    case('missing file', lambda: os.rename(f, f + '.x'), lambda: os.rename(f + '.x', f))
    case('extra file', lambda: open(d + '/extra', 'w').close(), lambda: os.unlink(d + '/extra'))
    case('size changed', lambda: os.truncate(f, st.st_size + 1), lambda: (os.truncate(f, st.st_size), os.utime(f, ns=(st.st_atime_ns, st.st_mtime_ns))))
    case('mtime changed', lambda: os.utime(f, ns=(st.st_atime_ns, st.st_mtime_ns + 1)), lambda: os.utime(f, ns=(st.st_atime_ns, st.st_mtime_ns)))
    def sym(): os.rename(f, f + '.x'); os.symlink('/etc/hostname', f)
    def unsym(): os.unlink(f); os.rename(f + '.x', f)
    case('file replaced by symlink', sym, unsym)
    def retype(): os.rename(f, f + '.x'); os.mkdir(f)
    def unretype(): os.rmdir(f); os.rename(f + '.x', f)
    case('file replaced by directory', retype, unretype)
    rc, out = run('verify', root, '--profile', 'expansion-10k'); ck('restored tree verifies again', rc == 0, out[-200:])
finally:
    shutil.rmtree(td, ignore_errors=True)
sys.exit(1 if fails else 0)
