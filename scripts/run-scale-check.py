#!/usr/bin/env python3
"""Single bounded Mac scale segment. Not called by CI, not permission to run.
Uses the existing prebuilt test app. Writes its own verdict only after the app's exact
result, assertion set, PNG and metrics exist. No repeated attempt and no user-file deletion.
Measurement semantics (intentional, do not change silently): the generator makes SPARSE files (ftruncate, zero allocated
bytes). The 'materialize' phase then writes ONE real byte at offset 0 of the 1-byte filter target
(expansion-1000000/f0000000.dat), keeping its size (1) and restoring its mtime, so the app's filter sees a file with allocated
bytes. This step does not exist in the 78d2345 runner. 'verify' checks the inventory only: relative path, kind, size and mtime
for every entry (spec hash), not file content; the one written byte therefore passes verify by design. The scale result is a
measurement over a sparse tree plus that single materialized file, not over 1M fully-allocated files.
Artifacts are retained below runner temp. The generated fixture is removed under the same segment deadline.
"""
import argparse, os, pathlib, signal, subprocess, sys, time

class Cancelled(Exception): pass

def run(argv, timeout, *, env=None, log=None):
    """Run argv, stream its output to the job log AND to `log` (a file kept as an artifact), kill it at `timeout`."""
    if log is None:
        p=subprocess.run(argv, timeout=timeout, env=env)
        if p.returncode: raise RuntimeError(f'command failed ({p.returncode}): {argv[0]}')
        return
    with open(log,'ab') as lf:
        p=subprocess.Popen(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        end=time.monotonic()+timeout
        import selectors
        sel=selectors.DefaultSelector(); sel.register(p.stdout, selectors.EVENT_READ)
        try:
            while True:
                left=end-time.monotonic()
                if left<=0:
                    p.kill(); p.wait(); raise subprocess.TimeoutExpired(argv, timeout)
                for _k,_ in sel.select(min(left,1.0)):
                    chunk=os.read(p.stdout.fileno(), 65536)
                    if chunk: lf.write(chunk); lf.flush(); sys.stdout.buffer.write(chunk); sys.stdout.flush()
                if p.poll() is not None:
                    chunk=p.stdout.read()
                    if chunk: lf.write(chunk); sys.stdout.buffer.write(chunk); sys.stdout.flush()
                    break
        except BaseException:
            if p.poll() is None: p.kill(); p.wait()
            raise
    if p.returncode: raise RuntimeError(f'command failed ({p.returncode}): {argv[0]}')

def write_verdict(w, status, reason, phases):
    """ALWAYS-written verdict: first line is the machine status (PASS | FAIL | INCOMPLETE | NOT-RUN), then the reason and the
    per-phase timing log. Only PASS counts as evidence; anything else is a failed/unproven segment."""
    try:
        lines=[f'{status} {reason}'.rstrip()]+[f'phase {n}: {st} elapsed={dt:.1f}s' for n,st,dt in phases]
        (w/'segment-verdict.txt').write_text('\n'.join(lines)+'\n')
    except OSError as e:
        print(f'could not write verdict: {e}',file=sys.stderr)

def segment(a, app, w, generator, *, profile='expansion-1m', target_rel='expansion-1000000/f0000000.dat'):
    fixture=w/'fixture';res=w/'result'
    deadline=time.monotonic()+min(a.budget_seconds,a.available)
    phases=[]
    # Reserve210s for app work, exit/termination, bounded fixture deletion and verdict.
    def left(reserve=0):
        n=int(deadline-time.monotonic())-reserve
        if n<=0: raise RuntimeError('INCOMPLETE: segment budget exhausted')
        return n
    def phase(name, fn):
        t=time.monotonic()
        try: fn()
        except BaseException:
            phases.append((name,'not-completed',time.monotonic()-t)); raise
        phases.append((name,'ok',time.monotonic()-t))
    def on_signal(s,_f): raise Cancelled('cancelled by '+signal.Signals(s).name)
    signal.signal(signal.SIGTERM, on_signal); signal.signal(signal.SIGINT, on_signal)
    try:
        phase('generate', lambda: run([sys.executable,generator,'generate',str(fixture),'--profile',profile],left(210),log=w/'generator.log'))
        # Sparse fixtures otherwise have zero allocated bytes. Materialize the exact
        #1-byte filter target, preserving its expected size and mtime before verification.
        def materialize():
            target=fixture/target_rel
            st=target.stat()
            with target.open('r+b') as f: f.write(b'x')
            os.utime(target,ns=(st.st_atime_ns,st.st_mtime_ns))
        phase('materialize', materialize)
        phase('verify', lambda: run([sys.executable,generator,'verify',str(fixture),'--profile',profile],left(210),log=w/'verify.log'))
        env=dict(os.environ,SPZ_CHECKS='scale',SPZ_SCALE_ROOT=str(fixture),SPZ_RESULT_DIR=str(res))
        # Direct unique child PID only. No pkill/process-name targeting or other app interaction.
        app_timeout=left(40)  # compute before spawning; budget failure must not orphan a child
        def runapp():
            with (w/'stdout.log').open('wb') as out, (w/'stderr.log').open('wb') as err:
                p=subprocess.Popen([str(app/'Contents/MacOS/Spacelyzer')],env=env,stdout=out,stderr=err)
                try: rc=p.wait(timeout=app_timeout)
                except BaseException as e:
                    p.terminate()
                    try: p.wait(timeout=5)
                    except subprocess.TimeoutExpired: p.kill();p.wait(timeout=5)
                    if isinstance(e,subprocess.TimeoutExpired): raise RuntimeError('INCOMPLETE: scale child exceeded segment budget')
                    raise
            if rc!=0: raise RuntimeError(f'FAIL scale app exit={rc}')
        phase('app', runapp)
        phase('validate', lambda: validate_result(res))
        # Delete only our newly-created, verified fixture after our child exited. No user paths.
        # Bounded cleanup is required, not an ignored finally that could consume the whole job.
        def cleanup():
            run(['/bin/rm','-rf',str(fixture)],left(10))
            if fixture.exists(): raise RuntimeError('INCOMPLETE: fixture cleanup did not finish')
        phase('cleanup', cleanup)
    except subprocess.TimeoutExpired as e:
        write_verdict(w,'INCOMPLETE',f'phase exceeded its share of the segment budget ({e.cmd[1] if len(e.cmd)>1 else e.cmd[0]} timed out after {e.timeout}s); fixture and partial output left in place for the artifact',phases); raise
    except Cancelled as e:
        write_verdict(w,'INCOMPLETE',str(e),phases); raise
    except Exception as e:
        msg=str(e); write_verdict(w,'INCOMPLETE' if msg.startswith('INCOMPLETE') else 'FAIL',msg,phases); raise
    write_verdict(w,'PASS','scale segment evidence present; pixels require independent inspection',phases)

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--app',required=True);ap.add_argument('--work',required=True)
    ap.add_argument('--budget-seconds',type=int,default=360)
    ap.add_argument('--job-deadline-epoch',type=float,required=True,
                    help='absolute whole-job deadline in Unix seconds, supplied by consolidated runner')
    ap.add_argument('--artifact-reserve-seconds',type=int,default=120)
    a=ap.parse_args()
    runner=os.environ.get('RUNNER_TEMP')
    w=pathlib.Path(a.work).resolve()
    workdir_ok=bool(runner) and pathlib.Path(runner).resolve() in w.parents and not w.exists()
    def early(status, msg):
        # Preconditions failed before any work: still leave a verdict artifact when our own fresh work dir is legitimate.
        if workdir_ok:
            w.mkdir(); (w/'result').mkdir(); write_verdict(w,status,msg,[])
        raise RuntimeError(msg)
    if sys.platform!='darwin': early('NOT-RUN','NOT-RUN: Mac scale segment needs macOS')
    if a.artifact_reserve_seconds < 120: early('FAIL','artifact reserve must be at least120s')
    available=a.job_deadline_epoch-time.time()-a.artifact_reserve_seconds
    if available < a.budget_seconds:
        early('INCOMPLETE','INCOMPLETE: whole-job deadline cannot reserve full scale segment plus artifacts')
    if not 240 <= a.budget_seconds <= 420: early('FAIL','budget must reserve 240..420 seconds')
    a.available=available
    app=pathlib.Path(a.app).resolve()
    if not runner or pathlib.Path(runner).resolve() not in w.parents: raise RuntimeError('work must be under RUNNER_TEMP')
    if w.exists(): raise RuntimeError('work must not exist (no overwrite or reuse)')
    if not (app/'Contents/MacOS/Spacelyzer').is_file(): early('FAIL','prebuilt test app missing')
    w.mkdir();(w/'result').mkdir()
    generator=str(pathlib.Path(__file__).with_name('make_fixtures.py'))
    segment(a,app,w,generator)

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
