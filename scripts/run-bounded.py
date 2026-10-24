#!/usr/bin/env python3
"""Bound a command and its descendants. Shared capture groups stay outer-owned."""
import subprocess,sys,os,signal

def kill_tree(pid):
    # Stop each parent before enumerating children, so no stopped process can
    # create a new child behind the walk. Never signal our own/outer group.
    try:os.kill(pid,signal.SIGSTOP)
    except ProcessLookupError:return
    rows=subprocess.check_output(['ps','-axo','pid=,ppid='],text=True)
    children=[int(row.split()[0]) for row in rows.splitlines() if len(row.split())==2 and int(row.split()[1])==pid]
    for child in children:kill_tree(child)
    try:os.kill(pid,signal.SIGKILL)
    except ProcessLookupError:pass

def main():
    shared=bool(os.environ.get('CAPTURE_SHARED_PROCESS_GROUP'))
    proc=subprocess.Popen(sys.argv[2:],start_new_session=not shared)
    try:return proc.wait(timeout=float(sys.argv[1]))
    except subprocess.TimeoutExpired:
        if shared:kill_tree(proc.pid)
        else:
            try:os.killpg(proc.pid,signal.SIGKILL)
            except ProcessLookupError:pass
        proc.wait()
        print('bounded: timed out after %ss: %s' % (sys.argv[1], ' '.join(sys.argv[2:4])),file=sys.stderr)
        return 124
if __name__=='__main__':sys.exit(main())
