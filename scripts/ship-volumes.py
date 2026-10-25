#!/usr/bin/env python3
"""Real-volume check for the ship-candidate run: mounts a real disk image inside a scan root, adds a mode-000 directory, runs the
environment-driven engine test (engine/tests/real_volume.rs) and judges its REAL-VOLUME lines. A missing case, a NOT-RUN case or an
unset environment is a failure. Mac execution is not proved by Linux tests."""
import argparse, os, pathlib, random, re, shutil, subprocess, sys, tempfile
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from ship_common import Checks

REQUIRED = ['volumes-fixture-mounted', 'volumes-test-ran', 'volumes-separate-volume-recorded', 'volumes-permission-denied-recorded',
            'volumes-cross-devices-descends', 'volumes-detach-during-scan-returns', 'volumes-summary-pass', 'volumes-cleanup-detached']
CASES = {'separate-volume-recorded': 'volumes-separate-volume-recorded', 'permission-denied-recorded': 'volumes-permission-denied-recorded',
         'cross-devices-descends': 'volumes-cross-devices-descends', 'detach-during-scan-returns': 'volumes-detach-during-scan-returns'}
HIDDEN_BYTES = 3 * 1024 * 1024


def judge(stdout, checks, test_rc):
    lines = [l[l.index('REAL-VOLUME'):] for l in stdout.splitlines() if 'REAL-VOLUME' in l]   # cargo prefixes the first --nocapture line with 'test ... '
    ran = bool(lines) and not any(l.startswith('REAL-VOLUME not-run') for l in lines)
    checks.check('volumes-test-ran', ran and test_rc is not None, f'lines={len(lines)} rc={test_rc}')
    seen = {}
    for l in lines:
        m = re.match(r'REAL-VOLUME case (\S+) (PASS|FAIL|NOT-RUN)\b(.*)', l)
        if m: seen.setdefault(m.group(1), []).append((m.group(2), m.group(3).strip()))
    for case, name in CASES.items():
        rows = seen.get(case, [])
        if len(rows) != 1: checks.bad(name, f'case line seen {len(rows)} times'); continue
        checks.check(name, rows[0][0] == 'PASS', f'{rows[0][0]} {rows[0][1][:300]}')
    summ = [l for l in lines if l.startswith('REAL-VOLUME summary')]
    checks.check('volumes-summary-pass', len(summ) == 1 and summ[0].endswith('PASS') and test_rc == 0, f'summary={summ} rc={test_rc}')


def run(out, attach, detach, test_cmd, mounted, make_img=None):
    """attach(mountpoint, work)->None, detach(mountpoint)->None, test_cmd(env)->(rc, stdout), mounted(mountpoint)->bool."""
    out = pathlib.Path(out); out.mkdir(parents=True, exist_ok=True)
    checks = Checks(REQUIRED)
    work = pathlib.Path(tempfile.mkdtemp(prefix='spz-vol-'))
    root = work / 'root'; vol = root / 'vol'; denied = root / 'denied'
    try:
        root.mkdir(); vol.mkdir(); denied.mkdir()
        (root / 'keep').write_bytes(bytes(5000)); (denied / 'secret.bin').write_bytes(bytes(100))
        denied.chmod(0)
        attach(str(vol), work)
        hidden = vol / 'hidden.bin'
        hidden.write_bytes(random.Random(3).randbytes(HIDDEN_BYTES))
        for i in range(3000): (vol / f'f{i:05d}.txt').write_bytes(b'x' * 100)   # keep the walk busy so a detach can land mid-scan
        if not checks.check('volumes-fixture-mounted', mounted(str(vol)) and hidden.is_file(), f'mounted={mounted(str(vol))}'): return checks
        env = {'SPZ_RV_ROOT': str(root), 'SPZ_RV_VOL': str(vol), 'SPZ_RV_DENIED': str(denied), 'SPZ_RV_HIDDEN': str(hidden),
               'SPZ_RV_HIDDEN_BYTES': str(HIDDEN_BYTES), 'SPZ_RV_DETACH': detach_cmd(str(vol))}
        rc, stdout = test_cmd(env)
        (out / 'real-volume-test.log').write_text(stdout[-60000:])
        judge(stdout, checks, rc)
    finally:
        try: denied.chmod(0o755)
        except OSError: pass
        try:
            if mounted(str(vol)): detach(str(vol))
        except Exception: pass
        checks.check('volumes-cleanup-detached', not mounted(str(vol)), 'volume no longer mounted')
        shutil.rmtree(work, ignore_errors=True)
    return checks


def detach_cmd(vol):
    return f"hdiutil detach -force '{vol}'" if sys.platform == 'darwin' else f"umount '{vol}'"


def mac_attach(vol, work):
    img = work / 'spz.sparseimage'
    subprocess.run(['hdiutil', 'create', '-size', '200m', '-fs', 'APFS', '-volname', 'SPZVOL', '-type', 'SPARSE', str(img)], check=True, timeout=120, capture_output=True)
    subprocess.run(['hdiutil', 'attach', str(img), '-mountpoint', vol, '-nobrowse', '-noverify'], check=True, timeout=120, capture_output=True)

def mac_detach(vol): subprocess.run(['hdiutil', 'detach', '-force', vol], timeout=120, capture_output=True)

def mac_mounted(vol):
    p = subprocess.run(['mount'], capture_output=True, text=True, timeout=30)
    return f' on {os.path.realpath(vol)} (' in p.stdout or f' on {vol} (' in p.stdout

def cargo_test(env):
    p = subprocess.run(['cargo', 'test', '--manifest-path', 'engine/Cargo.toml', '--test', 'real_volume', '--', '--nocapture', '--test-threads=1'],
                       capture_output=True, text=True, timeout=900, env=dict(os.environ, **env))
    return p.returncode, p.stdout + p.stderr


def main():
    p = argparse.ArgumentParser(); p.add_argument('--output', required=True); a = p.parse_args()
    checks = run(a.output, mac_attach, mac_detach, cargo_test, mac_mounted)
    good = checks.write(a.output)
    print(open(pathlib.Path(a.output) / 'result.txt').read(), end='')
    return 0 if good else 1

if __name__ == '__main__':
    sys.exit(main())
