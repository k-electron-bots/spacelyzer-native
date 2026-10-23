#!/usr/bin/env python3
"""Required ordering segment after demo evidence. Mac execution is not proved by Linux tests."""
import argparse, pathlib, shutil, subprocess, sys, tempfile, time

WORK_SECONDS = 330
ARTIFACT_SECONDS = 160
TEARDOWN_SECONDS = 200

def admission(deadline, now):
    remaining = deadline - now
    required = WORK_SECONDS + ARTIFACT_SECONDS + TEARDOWN_SECONDS
    if remaining < required:
        raise RuntimeError(f'INCOMPLETE: ordering requires {required}s remaining, has {remaining:.1f}s')
    return min(deadline - ARTIFACT_SECONDS - TEARDOWN_SECONDS, now + WORK_SECONDS)

def verify_result(result_dir, names):
    result_dir = pathlib.Path(result_dir)
    expected = f'PASS {len(names)} required checks, each exactly once'
    if (result_dir / 'result.txt').read_text().splitlines() != [expected]:
        raise RuntimeError('ordering result missing or not a clean exact-manifest pass')
    results = []
    for line in (result_dir / 'assertions.txt').read_text().splitlines():
        if line.startswith(('PASS ', 'FAIL ')):
            results.append(tuple(line.split(' ', 2)[:2]))
    if len(results) != len(names) or {n for _, n in results} != set(names):
        raise RuntimeError('ordering names missing, duplicated or unlisted')
    if any(status != 'PASS' for status, _ in results):
        raise RuntimeError('ordering assertion failed')

def stop_apps(deadline):
    def cmd(argv, **kwargs):
        return subprocess.run(argv, timeout=max(.01, deadline-time.time()), **kwargs)
    cmd(['pkill', '-x', 'Spacelyzer'], check=False)
    for _ in range(30):
        p = cmd(['pgrep', '-x', 'Spacelyzer'], capture_output=True)
        if p.returncode == 1:
            return
        if p.returncode != 0:
            raise RuntimeError('cannot verify prior app absence')
        time.sleep(.1)
    cmd(['pkill', '-9', '-x', 'Spacelyzer'], check=False)
    time.sleep(.2)
    if cmd(['pgrep', '-x', 'Spacelyzer'], capture_output=True).returncode != 1:
        raise RuntimeError('prior app still running; refusing ordering launch')

def run(app, output, deadline):
    output = pathlib.Path(output)
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise RuntimeError('ordering output must be fresh and empty')
    # Admit BEFORE creating a fixture or starting any process. Denial is a required failure.
    work_deadline = admission(deadline, time.time())
    def checked(argv):
        remaining = work_deadline - 5 - time.time()
        if remaining <= 0: raise RuntimeError('ordering work deadline exhausted')
        return subprocess.run(argv, check=True, timeout=remaining)
    checked([sys.executable, 'scripts/check-ordering-manifest.py'])
    import re
    source = pathlib.Path('Sources/Spacelyzer/SpacelyzerApp.swift').read_text()
    driver = source[source.index('@MainActor enum OrderingDriver'):]
    required = driver[driver.index('static let required'):driver.index('static func run')]
    names = re.findall(r'"([^"\n]+)"', required)
    if not names or len(set(names)) != len(names):
        raise RuntimeError('cannot read exact ordering manifest')
    work = pathlib.Path(tempfile.mkdtemp(prefix='spz-ordering-'))
    try:
        res = work / 'results'; res.mkdir()
        fix = work / 'fixture'; (fix / 'd').mkdir(parents=True)
        (fix / 'a.bin').write_bytes(bytes(200000)); (fix / 'd/b.bin').write_bytes(bytes(100000))
        bundle = work / 'Spacelyzer.app'
        shutil.copytree(app, bundle)
        import plistlib, uuid
        info = bundle / 'Contents/Info.plist'
        data = plistlib.loads(info.read_bytes())
        data['CFBundleIdentifier'] = 'com.k-electron.spacelyzer-native.ordering.' + uuid.uuid4().hex
        info.write_bytes(plistlib.dumps(data))
        checked(['codesign', '--force', '--deep', '--sign', '-', '--entitlements', 'Resources/Spacelyzer.entitlements', str(bundle)])
        checked(['codesign', '--verify', '--deep', '--strict', str(bundle)])
        stop_apps(work_deadline)
        if time.time() >= work_deadline:
            raise RuntimeError('ordering setup exhausted work deadline')
        env = dict(__import__('os').environ, SPZ_AUTOSCAN=str(fix), SPZ_DEMO='1', SPZ_CHECKS='ordering', SPZ_RESULT_DIR=str(res))
        with (work/'stdout.log').open('w') as stdout, (work/'stderr.log').open('w') as stderr:
            child = subprocess.Popen([str(bundle/'Contents/MacOS/Spacelyzer')], env=env, stdout=stdout, stderr=stderr, start_new_session=True)
            try:
                rc = child.wait(timeout=max(.01, work_deadline-5-time.time()))
                if rc != 0: raise RuntimeError(f'ordering process exit {rc}')
            except BaseException:
                import os, signal
                try: os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError: pass
                try: child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL); child.wait()
                raise
        verify_result(res, names)
        (output/'segment-verdict.txt').write_text('PASS required ordering segment\n')
    finally:
        # Preserve partial evidence even when names/time/process checks fail.
        for p in work.iterdir():
            if p.name == 'results': shutil.copytree(p, output/'results', dirs_exist_ok=True)
            elif p.suffix == '.log': shutil.copy2(p, output/p.name)
        try: stop_apps(work_deadline)
        finally: shutil.rmtree(work)

def main():
    p = argparse.ArgumentParser(); p.add_argument('--app', required=True); p.add_argument('--output', required=True)
    p.add_argument('--job-deadline', required=True, type=float); a = p.parse_args()
    try: run(a.app, a.output, a.job_deadline)
    except Exception as e:
        out = pathlib.Path(a.output); out.mkdir(parents=True, exist_ok=True)
        (out/'segment-verdict.txt').write_text('FAIL '+str(e)+'\n')
        print('FAIL ordering:', e, file=sys.stderr); return 1
    return 0
if __name__ == '__main__': sys.exit(main())
