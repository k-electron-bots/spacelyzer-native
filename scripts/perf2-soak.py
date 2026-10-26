#!/usr/bin/env python3
"""Engine rescan memory plateau on the real runner. Usage: perf2-soak.py --spz BIN --root DIR --reps N --out DIR [--tolerance 0.05] [--window 10]
Runs `spz bench ROOT N` (N repeated full scans in ONE process), samples the live RSS (ps) every ~0.05 s, and records the time each "run i:" line appears.
Per-scan figure = the LOWEST live RSS sample inside that scan's window (the floor after the previous tree is freed; maxima and end-of-scan points swing with allocation phase). PLATEAU = growth of the median of the last W scans over the median of the W scans before them is under tolerance (default 5%, W=10 over 40 scans; measured allocator noise on a 35 MB base was +-10% per scan, so 5-scan windows false-failed an honest engine). The peak-rss printed by bench is a process high-water mark and is NOT used. Scope: engine process only, not the Swift app.
Verdict: PASS / FAIL (growth over tolerance) / INCOMPLETE (fewer scans than needed, or too few samples)."""
import argparse, os, subprocess, sys, threading, time, json
def rss_kb(pid):
    try: return int(subprocess.run(['ps', '-o', 'rss=', '-p', str(pid)], capture_output=True, text=True).stdout.strip() or 0)
    except ValueError: return 0
def analyze(bounds, samples, window, tol):
    """bounds: end time of each scan (end time of each scan). samples: [(t, kb)]."""
    if len(bounds) < 2 * window: return 'INCOMPLETE', [f'only {len(bounds)} scans completed; need at least {2 * window} (two windows of {window})'], []
    peaks = []; used = []
    prev_b = samples[0][0] if samples else 0
    for b in bounds:
        win = [(t, kb) for t, kb in samples if prev_b < t <= b and kb > 0]
        if win: m = min(win, key=lambda x: x[1]); peaks.append(m[1]); used.append(m[0])
        else: peaks.append(0); used.append(0)
        prev_b = b
    if any(p == 0 for p in peaks): return 'INCOMPLETE', [f'scan(s) with no RSS sample inside the scan window (kB: {peaks})'], peaks
    last = peaks[-window:]; prev = peaks[-2 * window:-window]; med = lambda x: sorted(x)[len(x) // 2]; ml, mp = med(last), med(prev); g = (ml - mp) / mp
    d = [f'lowest live RSS inside each scan window (kB): {peaks}', f'distinct samples behind those {len(peaks)} figures: {len(set(used))} (fewer means scans ended between samples)', f'median of last {window} scans {ml:.0f} kB vs median of the {window} before {mp:.0f} kB: growth {g * 100:.2f}% (tolerance {tol * 100:.0f}%)']
    return ('PASS' if g < tol else 'FAIL'), d, peaks
def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--spz', required=True); ap.add_argument('--root', required=True); ap.add_argument('--reps', type=int, default=40)
    ap.add_argument('--out', required=True); ap.add_argument('--tolerance', type=float, default=0.05); ap.add_argument('--window', type=int, default=10); ap.add_argument('--timeout', type=float, default=240)
    a = ap.parse_args(); os.makedirs(a.out, exist_ok=True)
    p = subprocess.Popen([a.spz, 'bench', a.root, str(a.reps)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    samples = []; bounds = []; lines = []; stop = threading.Event()
    def sampler():
        while not stop.is_set(): samples.append((time.time(), rss_kb(p.pid))); time.sleep(0.05)
    th = threading.Thread(target=sampler, daemon=True); th.start(); t0 = time.time()
    killer = threading.Timer(a.timeout, lambda: p.kill()); killer.start()
    for line in p.stdout:
        lines.append(line.rstrip())
        if line.startswith('run '): bounds.append(time.time())
    rc = p.wait(); killer.cancel(); stop.set(); th.join(2)
    v, d, peaks = analyze(bounds, samples, a.window, a.tolerance)
    if rc != 0 and v == 'PASS': v, d = 'INCOMPLETE', [f'bench exited rc={rc}'] + d
    open(os.path.join(a.out, 'bench.log'), 'w').write('\n'.join(lines) + '\n')
    json.dump({'samples': samples, 'bounds': bounds, 'peaks_kb': peaks, 'rc': rc}, open(os.path.join(a.out, 'soak.json'), 'w'))
    open(os.path.join(a.out, 'soak-verdict.txt'), 'w').write(v + '\n' + '\n'.join(d) + f'\nscans={len(bounds)} rc={rc} seconds={time.time() - t0:.0f}\n')
    print(v, *d, sep='\n'); return 0
if __name__ == '__main__': sys.exit(main())
