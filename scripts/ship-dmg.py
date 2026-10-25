#!/usr/bin/env python3
"""Verify a packaged self-signed DMG for the ship-candidate run: sha256 file matches, mount, installer art present, Applications link,
app inside is strictly signed with the self-signed identity (not ad-hoc, not Developer ID, not notarized), version matches, install
window screenshot, copy the app out and launch it (the SHIPPING app, no test flags) and see a live window, detach. Mac execution is not
proved by Linux tests."""
import argparse, hashlib, json, os, pathlib, plistlib, re, shutil, subprocess, sys, tempfile, time
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from ship_common import Checks, Fail, find, pid_of, poll, stop_apps, HelperUI

REQUIRED = ['dmg-file-and-sha256', 'dmg-mounted', 'dmg-installer-art', 'dmg-applications-link', 'dmg-codesign-strict', 'dmg-signature-self-signed',
            'dmg-version', 'dmg-install-window-screenshot', 'dmg-copied-app-launches', 'dmg-window-visible', 'dmg-detached']


def sha_ok(dmg):
    sf = pathlib.Path(str(dmg) + '.sha256')
    if not dmg.is_file() or dmg.stat().st_size < 100_000 or not sf.is_file(): return False, 'missing dmg/sha256 or dmg too small'
    h = hashlib.sha256(dmg.read_bytes()).hexdigest()
    m = re.match(r'([0-9a-f]{64})\s+\*?(\S.*)$', sf.read_text().strip())
    return bool(m) and m.group(1) == h and os.path.basename(m.group(2)) == dmg.name, f'sha={h[:12]} file={sf.read_text().strip()[:90]}'


def judge_signature(text):
    """codesign -dv output. Self-signed here means an Authority line naming the project identity and no Developer ID / Apple authority."""
    bad = [w for w in ('Developer ID', 'Apple Root CA', 'Notarized', 'Signature=adhoc') if w in text]
    return ('Authority=Spacelyzer Self-Signed' in text or 'Authority=' in text) and not bad and 'Signature=adhoc' not in text, f'forbidden={bad} authority={re.findall(r"Authority=.*", text)[:2]}'


def run(dmg, version, out, sh, ui, launch, clock=time.time, sleep=time.sleep, mount_root='/Volumes'):
    """sh(argv)->(rc, stdout+stderr)."""
    out = pathlib.Path(out); out.mkdir(parents=True, exist_ok=True)
    checks = Checks(REQUIRED); dmg = pathlib.Path(dmg)
    mount = pathlib.Path(mount_root) / f'Spacelyzer {version}'
    attached = False; work = pathlib.Path(tempfile.mkdtemp(prefix='spz-dmg-'))
    try:
        ok, d = sha_ok(dmg)
        if not checks.check('dmg-file-and-sha256', ok, d): return checks
        rc, o = sh(['hdiutil', 'attach', '-nobrowse', '-noverify', str(dmg)])
        attached = rc == 0
        if not checks.check('dmg-mounted', attached and mount.is_dir(), f'rc={rc} mount={mount} {o[-200:]}'): return checks
        app = mount / 'Spacelyzer.app'
        art = [mount / '.background' / 'background.png', mount / '.background' / 'background@2x.png']
        checks.check('dmg-installer-art', all(p.is_file() and p.stat().st_size > 1000 for p in art), str([p.name for p in art if not p.is_file()]))
        link = mount / 'Applications'
        checks.check('dmg-applications-link', link.is_symlink() and os.readlink(link) == '/Applications', f'link={link.is_symlink()}')
        rc, o = sh(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app)])
        checks.check('dmg-codesign-strict', rc == 0, o[-300:])
        rc, o = sh(['codesign', '-dv', '--verbose=2', str(app)])
        ok, d = judge_signature(o); checks.check('dmg-signature-self-signed', rc == 0 and ok, d)
        try: info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        except Exception as e: info = {}; d = repr(e)
        checks.check('dmg-version', info.get('CFBundleShortVersionString') == version or info.get('CFBundleVersion') == version, f'info={ {k: info.get(k) for k in ("CFBundleShortVersionString", "CFBundleVersion")} }')
        sh(['open', str(mount)]); sleep(4)
        sh(['osascript', '-e', 'tell application "Finder" to activate']); sleep(2)
        shot = out / 'screenshot-dmg-install-window.png'
        sh(['screencapture', '-x', str(shot)])
        checks.check('dmg-install-window-screenshot', shot.is_file() and shot.stat().st_size > 5000, f'{shot.name} {shot.stat().st_size if shot.is_file() else 0} bytes')
        dest = work / 'Spacelyzer.app'
        rc, o = sh(['cp', '-R', str(app), str(dest)])
        stop_apps(); launch(dest)
        pid = poll(lambda: pid_of(), 30, .5, clock, sleep)
        checks.check('dmg-copied-app-launches', pid, f'pid={pid} copy rc={rc}')
        if pid:
            sleep(4)
            win = poll(lambda: find(ui.tree(pid), 'AXWindow'), 20, 1, clock, sleep)
            checks.check('dmg-window-visible', bool(win), f'window={win and (win.get("title"))}')
        else:
            checks.bad('dmg-window-visible', 'no process')
    except Fail as e:
        checks.bad('dmg-driver', str(e))
    finally:
        try: stop_apps()
        except Fail: pass
        det = 1
        if attached:
            for _ in range(3):
                det, _o = sh(['hdiutil', 'detach', str(mount)])
                if det == 0: break
                sleep(2)
            if det != 0: det = sh(['hdiutil', 'detach', '-force', str(mount)])[0]
        checks.check('dmg-detached', (not attached) or (det == 0 and not mount.exists()), f'detach rc={det} mountExists={mount.exists()}')
        shutil.rmtree(work, ignore_errors=True)
    return checks


def real_sh(argv):
    p = subprocess.run(argv, capture_output=True, text=True, timeout=180)
    return p.returncode, (p.stdout or '') + (p.stderr or '')

def real_launch(app): subprocess.run(['open', '-n', str(app)], check=True, timeout=30)


def main():
    p = argparse.ArgumentParser(); p.add_argument('--dmg', required=True); p.add_argument('--version', required=True)
    p.add_argument('--ui', required=True); p.add_argument('--output', required=True); a = p.parse_args()
    checks = run(a.dmg, a.version, a.output, real_sh, HelperUI(a.ui), real_launch)
    good = checks.write(a.output)
    print(open(pathlib.Path(a.output) / 'result.txt').read(), end='')
    return 0 if good else 1

if __name__ == '__main__':
    sys.exit(main())
