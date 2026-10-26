#!/usr/bin/env python3
"""Sample one process's RSS (ps, kB) every second into a file until it exits or is killed. Usage: perf2-rss.py PID OUTFILE. Informational series only."""
import subprocess, sys, time
pid, out = sys.argv[1], sys.argv[2]
with open(out, 'w') as f:
    f.write('epoch rss_kb\n')
    while True:
        r = subprocess.run(['ps', '-o', 'rss=', '-p', pid], capture_output=True, text=True).stdout.strip()
        if not r: break
        f.write(f'{time.time():.1f} {r}\n'); f.flush(); time.sleep(1)
