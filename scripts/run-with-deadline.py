#!/usr/bin/env python3
"""Run a command under the shared compile work deadline. Usage: run-with-deadline.py CMD [ARGS...]
SPZ_COMPILE_DEADLINE_EPOCH unset or empty: exec the command unchanged (non-compile_only modes are not affected).
Set: if the deadline already passed, do NOT start the command (exit 124). Otherwise run it in its own process group and,
at the deadline, SIGTERM then (after 10 s) SIGKILL the whole group and exit 124. SIGTERM/SIGINT to this wrapper (job cancel)
are forwarded to the group. The command's own exit code is returned otherwise. Never weakens a check: a timeout is a failure."""
import os, signal, subprocess, sys, time
argv = sys.argv[1:]
if not argv: sys.exit(64)
dl = os.environ.get('SPZ_COMPILE_DEADLINE_EPOCH', '')
if not dl: os.execvp(argv[0], argv)
deadline = int(dl)
if time.time() >= deadline:
    print(f'::error title=compile-deadline::compile work deadline already passed; not starting: {argv[0]}', file=sys.stderr); sys.exit(124)
p = subprocess.Popen(argv, start_new_session=True)
def kill(sig):
    try: os.killpg(p.pid, sig)
    except ProcessLookupError: pass
def fwd(signum, _f):
    kill(signal.SIGTERM); time.sleep(2); kill(signal.SIGKILL); sys.exit(128 + signum)
signal.signal(signal.SIGTERM, fwd); signal.signal(signal.SIGINT, fwd)
while True:
    rc = p.poll()
    if rc is not None: sys.exit(rc)
    if time.time() >= deadline:
        print(f'::error title=compile-deadline::compile work deadline reached; killing {argv[0]} process group', file=sys.stderr)
        kill(signal.SIGTERM)
        for _ in range(100):
            if p.poll() is not None: break
            time.sleep(0.1)
        kill(signal.SIGKILL); p.wait(); sys.exit(124)
    time.sleep(0.2)
