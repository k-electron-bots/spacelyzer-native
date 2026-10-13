#!/usr/bin/env python3
# evaluate.py <measure-out-dir> - verdicts against the pre-registered bars in env.
# Never crashes the step: each evaluation is independent and partial evidence is preserved.
import json, os, sys, glob, statistics, re

out = sys.argv[1] if len(sys.argv) > 1 else "measure-out"
verdicts = []
def verdict(name, status, detail):
    verdicts.append(f"{status} {name}: {detail}")

def read_jsonl(path):
    rows = []
    try:
        for line in open(path):
            line = line.strip()
            if line:
                try: rows.append(json.loads(line))
                except Exception: pass
    except FileNotFoundError:
        pass
    return rows

def dist(name, rows, p95_bar, max_bar):
    vals = [r["ms"] for r in rows if isinstance(r.get("ms"), (int, float))]
    if not vals:
        verdict(name, "INCONCLUSIVE", "no samples"); return
    vals.sort()
    p95 = vals[min(len(vals)-1, int(0.95*(len(vals)-1)))]
    mx = vals[-1]
    over_max = [v for v in vals if v > max_bar]
    over_p95 = p95 > p95_bar
    if over_max or over_p95:
        verdict(name, "OUTLIER", f"n={len(vals)} p95={p95:.1f}ms max={mx:.1f}ms bars p95<={p95_bar} max<={max_bar}; over-max count={len(over_max)}")
    else:
        verdict(name, "PASS", f"n={len(vals)} p95={p95:.1f}ms max={mx:.1f}ms bars p95<={p95_bar} max<={max_bar}")

def envf(k, d):
    try: return float(os.environ.get(k, d))
    except Exception: return d

for probe, envp, envm in [("type","STALL_TYPING_P95_MS","STALL_TYPING_MAX_MS"),
                          ("hover","STALL_HOVER_P95_MS","STALL_HOVER_MAX_MS"),
                          ("expand","STALL_EXPAND_P95_MS","STALL_EXPAND_MAX_MS")]:
    rows = [r for r in read_jsonl(os.path.join(out, "ax-type.jsonl")) + read_jsonl(os.path.join(out, "ax-expand.jsonl")) if r.get("probe")==probe]
    dist(f"stall-{probe}", rows, envf(envp,100), envf(envm,1000))

bl = [r["ms"] for r in read_jsonl(os.path.join(out,"ax-baseline.jsonl")) if isinstance(r.get("ms"),(int,float))]
if bl:
    bl.sort(); verdict("ax-overhead-baseline", "INFO", f"n={len(bl)} p50={statistics.median(bl):.1f}ms p95={bl[min(len(bl)-1,int(0.95*(len(bl)-1)))]:.1f}ms (instrumentation overhead, not app stall)")
else:
    verdict("ax-overhead-baseline", "INCONCLUSIVE", "no baseline samples")

# main-thread sample floor + block-gap heuristic
try:
    text = open(os.path.join(out,"main-thread-sample.txt"), errors="replace").read()
    snapshots = len(re.findall(r"^Analysis of sampling", text, re.M)) or text.count("Call graph")
    floor = int(envf("SAMPLE_MIN_SNAPSHOTS", 20))
    verdict("sample-floor", "PASS" if snapshots >= floor else "FAIL", f"snapshots={snapshots} floor={floor}")
    fail_ms = envf("MAIN_THREAD_BLOCK_FAIL_MS", 500); warn_ms = envf("MAIN_THREAD_BLOCK_WARN_MS", 100)
    # heuristic: identical consecutive main-thread lead frame outside known idle symbols
    frames = re.findall(r"Thread_.*?DispatchQueue_.*?main.*?\n\s+\d+\s+(\S+)", text)
    worst = 1; cur = 1
    for a, b in zip(frames, frames[1:]):
        idle = any(s in b for s in ("mach_msg", "semaphore_wait", "__psynch", "kevent", "poll", "read"))
        cur = cur + 1 if (a == b and not idle) else 1
        worst = max(worst, cur)
    gap_ms = worst * 10  # 10 ms sample interval
    st = "FAIL" if gap_ms >= fail_ms else ("OUTLIER" if gap_ms >= warn_ms else "PASS")
    verdict("main-thread-block", st, f"longest same-frame non-idle run ~{gap_ms}ms (10ms interval heuristic) fail>={fail_ms} warn>={warn_ms}")
except FileNotFoundError:
    verdict("main-thread-sample", "INCONCLUSIVE", "no sample file")

# soak: in-process growth from live-RSS timeline
try:
    rss = []
    for line in open(os.path.join(out, "bench15.liverss.log")):
        parts = line.split()
        if len(parts) >= 3:
            try: rss.append(int(parts[2]))
            except Exception: pass
    if len(rss) >= 6:
        third = max(1, len(rss)//3)
        first, last = statistics.median(rss[:third]), statistics.median(rss[-third:])
        growth = last / first if first else 0
        bar = envf("SOAK_GROWTH_MAX", 1.10)
        verdict("soak-inprocess-rss", "PASS" if growth <= bar else "OUTLIER", f"first-third median {first/1024:.1f}MB -> final-third {last/1024:.1f}MB growth={growth:.3f} bar<={bar} (shared runner, evidence not leak proof)")
    else:
        verdict("soak-inprocess-rss", "INCONCLUSIVE", f"only {len(rss)} live-RSS samples")
except FileNotFoundError:
    verdict("soak-inprocess-rss", "INCONCLUSIVE", "no live-RSS timeline")

# separate-process peaks band
try:
    peaks = [int(m.group(1)) for m in re.finditer(r"^\s*(\d+)\s+maximum resident set size", open(os.path.join(out,"separate10.log"), errors="replace").read(), re.M)]
    if peaks:
        band = envf("SOAK_SEPARATE_BAND", 0.10)
        med = statistics.median(peaks)
        ok = all(abs(p-med)/med <= band for p in peaks)
        verdict("soak-separate-peaks", "PASS" if ok else "OUTLIER", f"peaks MB={[round(p/1048576,1) for p in peaks]} band +/-{band} around median {med/1048576:.1f}MB")
    else:
        verdict("soak-separate-peaks", "INCONCLUSIVE", "no peaks parsed")
except FileNotFoundError:
    verdict("soak-separate-peaks", "INCONCLUSIVE", "no separate-process log")

# cancel cycles
cancel_rows = []
for f in glob.glob(os.path.join(out, "cancel-cycle-*.jsonl")):
    cancel_rows += read_jsonl(f)
press = [r for r in cancel_rows if r.get("probe")=="cancel-press"]
resp = [r for r in cancel_rows if r.get("probe")=="cancel-post-responsive"]
bar = envf("CANCEL_RESPONSIVE_MAX_MS", 1000)
if press and resp:
    worst = max(r["ms"] for r in resp if isinstance(r.get("ms"),(int,float)))
    verdict("cancel-responsive", "PASS" if worst <= bar else "OUTLIER", f"cycles={len(press)} post-cancel AX responsive worst={worst:.1f}ms bar<={bar}")
else:
    verdict("cancel-responsive", "INCONCLUSIVE", f"press={len(press)} resp={len(resp)}")

# poison named failure
try:
    log = open(os.path.join(out, "poison-scan.log"), errors="replace").read()
    rc = re.search(r"poison-scan-exit=(\d+)", log)
    named = bool(re.search(r"(Permission denied|permission|EACCES|error|failed|skipped)", log, re.I))
    crash = bool(re.search(r"(panic|SIGSEGV|SIGABRT|crash)", log, re.I))
    verdict("poison-failure", "PASS" if (named and not crash) else "FAIL", f"exit={rc.group(1) if rc else '?'} named-failure={named} crash={crash}; log preserved raw")
except FileNotFoundError:
    verdict("poison-failure", "INCONCLUSIVE", "no poison log")

# volume probes: report errno records verbatim; closure wording left to the report
for f in sorted(glob.glob(os.path.join(out, "nonutf8-*.txt"))):
    verdict(f"volume-{os.path.basename(f)}", "INFO", open(f).read().strip())

# cold launch informational
try:
    verdict("cold-launch", "INFO", "; ".join(open(os.path.join(out,"cold.log")).read().splitlines()))
except FileNotFoundError:
    verdict("cold-launch", "INCONCLUSIVE", "no cold log")

print("\n".join(verdicts) if verdicts else "no evaluations ran")
