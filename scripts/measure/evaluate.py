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
    # Pre-registered tail policy (binding): p95 AND max are both criteria.
    #   n < floor                      -> INCONCLUSIVE (thin run)
    #   p95 > bar                      -> FAIL
    #   >= 2 samples over max bar      -> FAIL
    #   exactly 1 over max bar         -> OUTLIER UNRESOLVED (no automatic PASS; adjudicate
    #                                     against the concurrent main-thread sample evidence)
    #   0 over max + p95 within + n ok -> PASS
    vals = [r["ms"] for r in rows if isinstance(r.get("ms"), (int, float))]
    floor = int(envf("DIST_MIN_SAMPLES", 20))
    if not vals:
        verdict(name, "INCONCLUSIVE", "no samples"); return
    if len(vals) < floor:
        verdict(name, "INCONCLUSIVE", f"n={len(vals)} below pre-registered sample floor {floor}; no verdict"); return
    vals.sort()
    p95 = vals[min(len(vals)-1, int(0.95*(len(vals)-1)))]
    mx = vals[-1]
    over_max = len([v for v in vals if v > max_bar])
    stats = f"n={len(vals)} p95={p95:.1f}ms max={mx:.1f}ms over-max count={over_max} bars p95<={p95_bar} max<={max_bar}"
    if p95 > p95_bar or over_max >= 2:
        verdict(name, "FAIL", stats + "; pre-registered criterion exceeded")
    elif over_max == 1:
        verdict(name, "OUTLIER", stats + "; UNRESOLVED pending concurrent main-thread sample adjudication - not a PASS")
    else:
        verdict(name, "PASS", stats)

def diag_summarize(rows):
    # bounded-ping-v1 telemetry rows -> (record counts by type, latched stall ms values,
    # max telemetry_write_errors seen). Malformed rows are skipped by read_jsonl already.
    by_type, stalls, errs = {}, [], 0
    for r in rows:
        t = r.get("type", "?")
        by_type[t] = by_type.get(t, 0) + 1
        if t == "stall" and isinstance(r.get("ms"), (int, float)):
            stalls.append(r["ms"])
        if isinstance(r.get("telemetry_write_errors"), int):
            errs = max(errs, r["telemetry_write_errors"])
    return by_type, stalls, errs

def envf(k, d):
    try: return float(os.environ.get(k, d))
    except Exception: return d

def poison_eval(log, denial):
    rc_m = re.search(r"poison-scan-exit=(\d+)", log)
    rc = int(rc_m.group(1)) if rc_m else -1
    sk_m = re.search(r"\((\d+) skipped\)", log)
    skipped = int(sk_m.group(1)) if sk_m else None
    panic = bool(re.search(r"(panic|scan failed|SIGSEGV|SIGABRT)", log))
    uid_m = re.search(r"runner-uid=(\d+)", denial or "")
    if denial is None or "PROBE-DENIED" not in denial or (uid_m and int(uid_m.group(1)) == 0):
        return ("INCONCLUSIVE",
                f"denial not confirmed (record={'present' if denial else 'missing'}, uid={uid_m.group(1) if uid_m else '?'}); permissions may not have been actually denied - no verdict")
    if rc != 0 or panic:
        return ("FAIL", f"exit={rc} panic={panic}; healthy partial scan requires exit 0 and no panic marker")
    if skipped == 1:
        return ("PASS", "exit=0 skipped=exactly-1 (sole constructed defect) panic=False; matches engine partial-scan semantics")
    return ("FAIL", f"exit=0 skipped={skipped}; expected exactly 1 (0 = defect silently dropped, 2+ = collateral skip)")


def selftest():
    # Synthetic regression: malformed/absent/healthy-minimal evidence must never render PASS
    # where it should not. Exits non-zero on any mismatch so the workflow step fails loudly.
    global verdicts
    fails = []
    def check(name, cond):
        if not cond: fails.append(name)
    os.environ["DIST_MIN_SAMPLES"] = "20"
    verdicts = []; dist("t", [{"ms": 1.0}] * 5, 100, 1000)
    check("thin-not-pass", verdicts[-1].startswith("INCONCLUSIVE"))
    verdicts = []; dist("t", [{"ms": 50.0}] * 25, 100, 1000)
    check("clean-pass", verdicts[-1].startswith("PASS"))
    verdicts = []; dist("t", [{"ms": 50.0}] * 24 + [{"ms": 1500.0}], 100, 1000)
    check("one-over-unresolved", verdicts[-1].startswith("OUTLIER") and "UNRESOLVED" in verdicts[-1])
    verdicts = []; dist("t", [{"ms": 50.0}] * 23 + [{"ms": 1500.0}, {"ms": 2000.0}], 100, 1000)
    check("two-over-fail", verdicts[-1].startswith("FAIL"))
    verdicts = []; dist("t", [{"ms": 200.0}] * 25, 100, 1000)
    check("p95-over-fail", verdicts[-1].startswith("FAIL"))
    # poison matrix
    denial_ok = "runner-uid=501\nPROBE-DENIED\n"
    check("healthy-partial-passes", poison_eval("12 items, 1.0 KB in 0.010s (1 skipped)\npoison-scan-exit=0\n", denial_ok)[0] == "PASS")
    check("zero-skipped-fails", poison_eval("12 items, 1.0 KB in 0.010s (0 skipped)\npoison-scan-exit=0\n", denial_ok)[0] == "FAIL")
    check("two-skipped-fails", poison_eval("12 items, 1.0 KB in 0.010s (2 skipped)\npoison-scan-exit=0\n", denial_ok)[0] == "FAIL")
    check("nonzero-exit-fails", poison_eval("boom\npoison-scan-exit=1\n", denial_ok)[0] == "FAIL")
    check("panic-fails", poison_eval("thread panicked at scan failed (1 skipped)\npoison-scan-exit=101\n", denial_ok)[0] == "FAIL")
    check("watchdog-fails", poison_eval("poison-scan-exit=124\n", denial_ok)[0] == "FAIL")
    check("missing-denial-inconclusive", poison_eval("(1 skipped)\npoison-scan-exit=0\n", None)[0] == "INCONCLUSIVE")
    check("root-denial-inconclusive", poison_eval("(1 skipped)\npoison-scan-exit=0\n", "runner-uid=0\nPROBE-DENIED\n")[0] == "INCONCLUSIVE")
    check("readable-probe-inconclusive", poison_eval("(1 skipped)\npoison-scan-exit=0\n", "runner-uid=501\nPROBE-READABLE\n")[0] == "INCONCLUSIVE")
    by_t, st, er = diag_summarize([{"type": "window", "telemetry_write_errors": 0},
                                   {"type": "stall", "ms": 123.4},
                                   {"type": "stall", "ms": "bad"},
                                   {"type": "window", "telemetry_write_errors": 2}])
    check("diag-counts", by_t == {"window": 2, "stall": 2} and st == [123.4] and er == 2)
    by_t, st, er = diag_summarize([])
    check("diag-empty", by_t == {} and st == [] and er == 0)
    if fails:
        print("SELFTEST FAIL: " + ", ".join(fails)); sys.exit(1)
    print("SELFTEST PASS: tail policy + poison semantics + denial gate + absent-evidence handling + diagnostic parse")
    sys.exit(0)

if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
    selftest()

for probe, envp, envm in [("type","STALL_TYPING_P95_MS","STALL_TYPING_MAX_MS"),
                          ("menu","STALL_MENU_P95_MS","STALL_MENU_MAX_MS"),
                          ("expand","STALL_EXPAND_P95_MS","STALL_EXPAND_MAX_MS")]:
    rows = [r for r in read_jsonl(os.path.join(out, "ax-type.jsonl")) + read_jsonl(os.path.join(out, "ax-expand.jsonl")) if r.get("probe")==probe]
    dist(f"stall-{probe}", rows, envf(envp,100), envf(envm,1000))

bl = [r["ms"] for r in read_jsonl(os.path.join(out,"ax-baseline.jsonl")) if isinstance(r.get("ms"),(int,float))]
if bl:
    bl.sort(); verdict("ax-overhead-baseline", "INFO", f"n={len(bl)} p50={statistics.median(bl):.1f}ms p95={bl[min(len(bl)-1,int(0.95*(len(bl)-1)))]:.1f}ms (instrumentation overhead, not app stall)")
else:
    verdict("ax-overhead-baseline", "INCONCLUSIVE", "no baseline samples")

# main-thread sample: CONTEXT ONLY. The aggregated `sample` report is one report without
# per-snapshot frames, so no snapshot floor and no main-thread block duration can be derived
# from it. It is preserved raw as context for adjudicating AX-side outliers; it closes no
# gate. The real main-thread stall gate remains UNCLOSED unless valid instrumentation lands.
try:
    raw = open(os.path.join(out,"main-thread-sample.txt"), errors="replace").read()
    verdict("main-thread-sample", "INFO",
            f"raw sample captured as context only ({len(raw)} bytes); not instrumentation; no block durations inferred; main-thread stall gate UNCLOSED")
except FileNotFoundError:
    verdict("main-thread-sample", "INCONCLUSIVE", "no sample file; nothing inferred either way")

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

# Instrumented diagnostic telemetry (bounded-ping-v1, launches labeled diagnostic):
# CONTEXT ONLY - never bar-compared, closes no gate. Reports the monitor's own records
# verbatim (counts by type, latched stalls, the monitor's write-error counter).
diag_files = sorted(glob.glob(os.path.join(out, "stall-telemetry", "diagnostic", "spz-stall-*.jsonl")))
if diag_files:
    for f in diag_files:
        by_t, st, er = diag_summarize(read_jsonl(f))
        detail = f"records={sum(by_t.values())} by_type={by_t} telemetry_write_errors={er}"
        if st:
            detail += f" latched-stalls n={len(st)} max={max(st):.1f}ms"
        verdict(f"diagnostic-{os.path.basename(f)}", "INFO", detail + "; diagnostic instrumentation, closes no gate")
else:
    verdict("diagnostic-stall-telemetry", "INCONCLUSIVE", "no diagnostic telemetry captured; scan-window stall investigation stays open")

# poison partial-scan check, driven by the engine's ACTUAL semantics (verified against
# engine/src/bin/spz.rs): an unreadable subtree is recorded in tree.skipped and the scan
# continues - healthy partial scan = exit 0, summary prints ONLY the skipped count.
# The fixture has exactly ONE defect by construction (chmod 000 subtree), so:
#   exit 0 + exactly 1 skipped + no panic + denial actually in effect  -> PASS
#   0 skipped (defect silently dropped) or 2+ (collateral skip)        -> FAIL
#   non-zero exit / watchdog 124 / panic marker                        -> FAIL
#   denial not confirmed (missing record, root user, readable probe)   -> INCONCLUSIVE
try:
    log = open(os.path.join(out, "poison-scan.log"), errors="replace").read()
    try:
        denial = open(os.path.join(out, "poison-denial.txt"), errors="replace").read()
    except FileNotFoundError:
        denial = None
    st, detail = poison_eval(log, denial)
    verdict("poison-partial-scan", st, detail + "; fixture: /tmp/spz-poison/sub chmod 000, sole constructed defect; log preserved raw")
except FileNotFoundError:
    verdict("poison-partial-scan", "INCONCLUSIVE", "no poison log")

# volume probes: report errno records verbatim; closure wording left to the report
for f in sorted(glob.glob(os.path.join(out, "nonutf8-*.txt"))):
    verdict(f"volume-{os.path.basename(f)}", "INFO", open(f).read().strip())

# cold launch informational
try:
    verdict("cold-launch", "INFO", "; ".join(open(os.path.join(out,"cold.log")).read().splitlines()))
except FileNotFoundError:
    verdict("cold-launch", "INCONCLUSIVE", "no cold log")

print("\n".join(verdicts) if verdicts else "no evaluations ran")
