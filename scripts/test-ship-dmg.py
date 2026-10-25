#!/usr/bin/env python3
"""Linux controls for scripts/package-dmg.sh (run against fake hdiutil/osascript/codesign/iconutil/lipo-free stubs, with the real script text)
and scripts/ship-dmg.py (fake shell and UI). Not macOS: real hdiutil, Finder, codesign and launch stay native-unverified."""
import importlib.util, os, pathlib, shutil, stat, subprocess, sys, tempfile, hashlib
sys.path.insert(0, 'scripts')
spec = importlib.util.spec_from_file_location('shipdmg', 'scripts/ship-dmg.py'); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def fake_bin(d, fail=None):
    b = pathlib.Path(d) / 'bin'; b.mkdir()
    def w(name, body):
        p = b / name; p.write_text('#!/bin/bash\n' + body); p.chmod(0o755)
    w('codesign', 'echo codesign "$@" >> "$FAKE_LOG"\n[ "$FAKE_FAIL" = codesign ] && [[ "$*" == *--verify* ]] && exit 1\nexit 0')
    w('iconutil', 'echo iconutil "$@" >> "$FAKE_LOG"\n[ "$FAKE_FAIL" = iconutil ] && exit 1\nout="${@: -1}"; echo icns > "$out"')
    w('osascript', 'echo osascript >> "$FAKE_LOG"\n[ "$FAKE_FAIL" = osascript ] && { echo "syntax error" >&2; exit 1; }\ncat > /dev/null')
    w('sync', 'exit 0')
    w('hdiutil', r'''echo hdiutil "$@" >> "$FAKE_LOG"
case "$1" in
 create) src=""; out=""; while [ $# -gt 0 ]; do case "$1" in -srcfolder) src="$2"; shift;; esac; out="$1"; shift; done
   mkdir -p "$(dirname "$out")"; cp -R "$src" "$out.d"; echo rw > "$out";;
 attach) rw="${@: -1}"; [ "$FAKE_FAIL" = attach ] && exit 1; mkdir -p "$SPZ_DMG_MOUNT_ROOT/Spacelyzer ${VERSION}"; cp -R "$rw.d/." "$SPZ_DMG_MOUNT_ROOT/Spacelyzer ${VERSION}/";;
 detach) rm -rf "$2";;
 convert) in="$2"; while [ $# -gt 0 ]; do case "$1" in -o) out="$2";; esac; shift; done; head -c 200000 /dev/zero > "$out"; echo done;;
esac''')
    return b

def run_pkg(fail=None):
    with tempfile.TemporaryDirectory() as t:
        t = pathlib.Path(t); repo = t / 'repo'; repo.mkdir()
        shutil.copytree('scripts', repo / 'scripts', ignore=shutil.ignore_patterns('__pycache__', 'fixtures', 'linux-*'))
        shutil.copytree('Resources', repo / 'Resources')
        (repo / 'build/lib').mkdir(parents=True); (repo / 'build/lib/libspacelyzer_engine.a').write_text('x')
        # stub the build helpers (this is the only replacement of repo scripts)
        (repo / 'scripts/shipping-swift.sh').write_text('#!/bin/bash\n[[ "$*" == *--show-bin-path* ]] && { echo "' + str(t / 'bin-out') + '"; exit 0; }\nexit 0\n')
        (repo / 'scripts/check-no-ci-symbols.sh').write_text('#!/bin/bash\nexit 0\n')
        (t / 'bin-out').mkdir(); (t / 'bin-out/Spacelyzer').write_text('binary')
        b = fake_bin(t); mnt = t / 'Volumes'; mnt.mkdir()
        env = dict(os.environ, PATH=f'{b}:{os.environ["PATH"]}', FAKE_LOG=str(t / 'log'), FAKE_FAIL=fail or '', SPZ_DMG_MOUNT_ROOT=str(mnt), VERSION='9.9.9', SPZ_DIST=str(repo / 'distpkg'))
        (repo / 'dist').mkdir(); (repo / 'dist/demo-evidence.txt').write_text('keep me')
        p = subprocess.run(['bash', 'scripts/package-dmg.sh', '9.9.9', 'IDENT'], cwd=repo, capture_output=True, text=True, env=env)
        out = repo / 'distpkg'
        d = out / 'Spacelyzer-9.9.9.dmg'; sfp = out / 'Spacelyzer-9.9.9.dmg.sha256'
        info = dict(dmg=d.is_file(), sha=sfp.read_text() if sfp.is_file() else '', digest=hashlib.sha256(d.read_bytes()).hexdigest() if d.is_file() else '', names=sorted(x.name for x in out.iterdir()) if out.exists() else None)
        return p, info, (repo / 'dist/demo-evidence.txt').exists(), (t / 'log').read_text() if (t / 'log').exists() else ''

p, out, kept, log = run_pkg()
assert p.returncode == 0, p.stderr[-1500:]
assert out['dmg'] and out['sha'] and kept, (out, kept)
assert 'codesign --force --deep --options runtime' in log and 'IDENT' in log and 'osascript' in log
assert out['sha'].split()[1] == 'Spacelyzer-9.9.9.dmg' and out['sha'].split()[0] == out['digest']
for fail in ('osascript', 'codesign', 'iconutil', 'attach'):
    p, out, kept, log = run_pkg(fail)
    assert p.returncode != 0 and not out['dmg'] and kept, (fail, p.returncode, out)
print('PASS package-dmg.sh with stubs: SPZ_DIST keeps demo evidence in dist/, sha256 file is relative and matches, and osascript, codesign, iconutil and attach failures each fail the script with no DMG left')

# ---- ship-dmg.py with a fake shell
class Clk:
    def __init__(s): s.t = 0.0
    def __call__(s): return s.t
    def sleep(s, d): s.t += max(d, .01)
class UI:
    def __init__(s, win=True): s.win = win
    def tree(s, pid): return [{'role': 'AXWindow', 'title': 'Spacelyzer'}] if s.win else [{'role': 'AXApplication'}]

def drive(**k):
    with tempfile.TemporaryDirectory() as t:
        t = pathlib.Path(t); mroot = t / 'Volumes'; mroot.mkdir(); mount = mroot / 'Spacelyzer 9.9.9'
        dmg = t / 'Spacelyzer-9.9.9.dmg'; dmg.write_bytes(b'd' * 300000)
        h = hashlib.sha256(dmg.read_bytes()).hexdigest()
        (t / 'Spacelyzer-9.9.9.dmg.sha256').write_text(f'{h}  Spacelyzer-9.9.9.dmg\n' if not k.get('badsha') else f'{"0"*64}  Spacelyzer-9.9.9.dmg\n')
        state = {'mounted': False}
        import plistlib
        def sh(argv):
            if argv[0] == 'hdiutil' and argv[1] == 'attach':
                if k.get('attach_fail'): return 1, 'no'
                (mount / 'Spacelyzer.app/Contents/MacOS').mkdir(parents=True); (mount / '.background').mkdir()
                for n in ('background.png', 'background@2x.png'): (mount / '.background' / n).write_bytes(b'p' * (0 if k.get('noart') else 5000))
                (mount / 'Applications').symlink_to('/Applications' if not k.get('badlink') else '/tmp')
                (mount / 'Spacelyzer.app/Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '1.0' if k.get('badver') else '9.9.9'}))
                state['mounted'] = True; return 0, ''
            if argv[0] == 'hdiutil' and argv[1] == 'detach':
                if k.get('stuck') and argv[-2] != '-force': return 1, 'busy'
                shutil.rmtree(mount, ignore_errors=True); return 0, ''
            if argv[0] == 'codesign' and '--verify' in argv: return (1, 'invalid') if k.get('badsign') else (0, 'valid')
            if argv[0] == 'codesign': return 0, ('Authority=Developer ID Application: X\n' if k.get('devid') else 'Signature=adhoc\n' if k.get('adhoc') else 'Authority=Spacelyzer Self-Signed\n')
            if argv[0] == 'screencapture': pathlib.Path(argv[-1]).write_bytes(b'png' * (0 if k.get('noshot') else 4000)); return 0, ''
            if argv[0] == 'cp': shutil.copytree(argv[2], argv[3]); return 0, ''
            return 0, ''
        clk = Clk()
        m.stop_apps = lambda *a, **kw: None
        m.pid_of = lambda *a, **kw: (None if k.get('nolaunch') else 55)
        c = m.run(dmg, '9.9.9', t / 'out', sh, UI(not k.get('nowin')), lambda app: None, clock=clk, sleep=clk.sleep, mount_root=str(mroot))
        return c.verdict(), mount.exists()

(g, p), left = drive(); assert g and not left, p
for name, kw, needle in [('bad sha', dict(badsha=1), 'dmg-file-and-sha256'), ('attach fails', dict(attach_fail=1), 'dmg-mounted'), ('no art', dict(noart=1), 'dmg-installer-art'),
        ('bad link', dict(badlink=1), 'dmg-applications-link'), ('bad signature', dict(badsign=1), 'dmg-codesign-strict'), ('developer id', dict(devid=1), 'dmg-signature-self-signed'),
        ('ad hoc', dict(adhoc=1), 'dmg-signature-self-signed'), ('wrong version', dict(badver=1), 'dmg-version'), ('no screenshot', dict(noshot=1), 'dmg-install-window-screenshot'),
        ('no launch', dict(nolaunch=1), 'dmg-copied-app-launches'), ('no window', dict(nowin=1), 'dmg-window-visible')]:
    (g, p), left = drive(**kw); assert not g and any(needle in x for x in p), (name, p)
(g, p), left = drive(stuck=1); assert g and not left, p   # busy detach falls back to -force and still ends detached
print('PASS dmg driver: green on a correct fake, red for bad sha, attach failure, missing art, bad Applications link, bad signature, Developer ID, ad-hoc, wrong version, no screenshot, no launch, no window; busy detach recovers with -force')
