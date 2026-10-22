#!/usr/bin/env python3
"""Single bounded Mac scale segment. Not called by CI, not permission to run.
Uses the existing prebuilt test app. Writes its own verdict only after the app's exact
result, assertion set, PNG and metrics exist. No repeated attempt and no user-file deletion.
Artifacts are retained below runner temp. The generated fixture is removed under the same segment deadline.
"""
import argparse, os, pathlib, subprocess, sys, time

def run(argv, timeout, *, env=None):
    p=subprocess.run(argv, timeout=timeout, env=env)
    if p.returncode: raise RuntimeError(f'command failed ({p.returncode}): {argv[0]}')

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--app',required=True);ap.add_argument('--work',required=True)
    ap.add_argument('--budget-seconds',type=int,default=360)
    ap.add_argument('--job-deadline-epoch',type=float,required=True,
                    help='absolute whole-job deadline in Unix seconds, supplied by consolidated runner')
    ap.add_argument('--artifact-reserve-seconds',type=int,default=120)
    a=ap.parse_args()
    if sys.platform!='darwin': raise RuntimeError('NOT-RUN: Mac scale segment needs macOS')
    if a.artifact_reserve_seconds < 120: raise RuntimeError('artifact reserve must be at least120s')
    available=a.job_deadline_epoch-time.time()-a.artifact_reserve_seconds
    if available < a.budget_seconds:
        raise RuntimeError('INCOMPLETE: whole-job deadline cannot reserve full scale segment plus artifacts')
    if not 240 <= a.budget_seconds <= 420: raise RuntimeError('budget must reserve 240..420 seconds')
    app=pathlib.Path(a.app).resolve();w=pathlib.Path(a.work).resolve()
    runner=os.environ.get('RUNNER_TEMP')
    if not runner or pathlib.Path(runner).resolve() not in w.parents: raise RuntimeError('work must be under RUNNER_TEMP')
    if w.exists(): raise RuntimeError('work must not exist (no overwrite or reuse)')
    if not (app/'Contents/MacOS/Spacelyzer').is_file(): raise RuntimeError('prebuilt test app missing')
    w.mkdir();fixture=w/'fixture';res=w/'result';res.mkdir()
    deadline=time.monotonic()+min(a.budget_seconds,available)
    # Reserve210s for app work, exit/termination, bounded fixture deletion and verdict.
    def left(reserve=0):
        n=int(deadline-time.monotonic())-reserve
        if n<=0: raise RuntimeError('INCOMPLETE: segment budget exhausted')
        return n
    generator=str(pathlib.Path(__file__).with_name('make_fixtures.py'))
    run([sys.executable,generator,'generate',str(fixture),'--profile','expansion-1m'],left(210))
    # Sparse fixtures otherwise have zero allocated bytes. Materialize the exact
    #1-byte filter target, preserving its expected size and mtime before verification.
    target=fixture/'expansion-1000000/f0000000.dat'
    st=target.stat()
    with target.open('r+b') as f: f.write(b'x')
    os.utime(target,ns=(st.st_atime_ns,st.st_mtime_ns))
    run([sys.executable,generator,'verify',str(fixture),'--profile','expansion-1m'],left(210))
    env=dict(os.environ,SPZ_CHECKS='scale',SPZ_SCALE_ROOT=str(fixture),SPZ_RESULT_DIR=str(res))
    # Direct unique child PID only. No pkill/process-name targeting or other app interaction.
    app_timeout=left(40)  # compute before spawning; budget failure must not orphan a child
    with (w/'stdout.log').open('wb') as out, (w/'stderr.log').open('wb') as err:
        p=subprocess.Popen([str(app/'Contents/MacOS/Spacelyzer')],env=env,stdout=out,stderr=err)
        try: rc=p.wait(timeout=app_timeout)
        except subprocess.TimeoutExpired:
            p.terminate()
            try: p.wait(timeout=5)
            except subprocess.TimeoutExpired: p.kill();p.wait(timeout=5)
            raise RuntimeError('INCOMPLETE: scale child exceeded segment budget')
    if rc!=0: raise RuntimeError(f'FAIL scale app exit={rc}')
    validate_result(res)
    # Delete only our newly-created, verified fixture after our child exited. No user paths.
    # Bounded cleanup is required, not an ignored finally that could consume the whole job.
    run(['/bin/rm','-rf',str(fixture)],left(10))
    if fixture.exists(): raise RuntimeError('INCOMPLETE: fixture cleanup did not finish')
    (w/'segment-verdict.txt').write_text('PASS scale segment evidence present; pixels require independent inspection\n')

def validate_result(res):
    required={'scale-real-scan-exact-million-item-tree','scale-mounted-million-row-publication',
              'scale-filter-exact-single-file','scale-clear-filter-restores-million-rows',
              'scale-main-queue-delay-under-250ms'}
    if (res/'result.txt').read_text()!='PASS 5 scale checks, each exactly once\n': raise RuntimeError('FAIL result header')
    rows=[line.split(' ',2) for line in (res/'assertions.txt').read_text().splitlines() if line.startswith(('PASS ','FAIL '))]
    if len(rows)!=5 or {r[1] for r in rows}!=required or any(r[0]!='PASS' for r in rows): raise RuntimeError('FAIL missing/duplicate/failing scale assertion')
    png=(res/'scale-mounted-window.png').read_bytes()
    if len(png)<32 or not png.startswith(b'\x89PNG\r\n\x1a\n'): raise RuntimeError('FAIL missing/invalid PNG artifact')
    if not (res/'scale-metrics.txt').read_text().strip(): raise RuntimeError('FAIL empty metrics')
if __name__=='__main__':
    try: main()
    except Exception as e: print(str(e),file=sys.stderr);sys.exit(1)
