#!/bin/bash
# Stability/responsiveness leg. Usage: perf2-stability.sh APP SPZ FIXDIR OUT SCRIPTS_DIR BENCH READINESS
#   FIXDIR holds typing/typing-200k and exp/ (as m3-first-run generated them). BENCH/READINESS are the compiled m3 tools.
# Parts run independently (a red part never hides the next). Each part appends "NAME STATUS detail" to OUT/parts.txt; the leg verdict is PASS only if every part PASS.
# No latency threshold is gated (none owner-approved); numbers are BASELINE evidence in the jsonl files.
set +e
APP="$1"; SPZ="$2"; FIX="$3"; OUT="$4"; SD="$5"; BENCH="$6"; READY="$7"
mkdir -p "$OUT"; : > "$OUT/parts.txt"
part() { echo "$1 $2 $3" >> "$OUT/parts.txt"; echo "part $1: $2 $3"; }
date -u +%s > "$OUT/start-epoch.txt"
crash_before=$(ls ~/Library/Logs/DiagnosticReports/Spacelyzer*.ips 2>/dev/null | wc -l | tr -d ' ')
launch() {   # launch NAME ROOT ; sets PID or empty
  PID=""
  pgrep -x Spacelyzer >/dev/null && { echo "PRECHECK FAILED: Spacelyzer already running"; return 1; }
  rm -f /tmp/spz-timing.txt
  open -n "$APP" --env SPZ_AUTOSCAN="$2" --env SPZ_TIMING=1
  for i in $(seq 1 30); do n=$(pgrep -x Spacelyzer | wc -l | tr -d ' '); [ "$n" = "1" ] && { PID=$(pgrep -x Spacelyzer); break; }; sleep 1; done
  [ -n "$PID" ] || { echo "APP DID NOT LAUNCH UNIQUELY"; return 1; }
  python3 "$SD/perf2-rss.py" "$PID" "$OUT/app-rss-$1.txt" & RSSPID=$!
  return 0
}
finish() { kill "$PID" 2>/dev/null; sleep 1; kill -9 "$PID" 2>/dev/null; kill "$RSSPID" 2>/dev/null; wait "$RSSPID" 2>/dev/null; PID=""; }
ready() {   # ready NAME ROOT SECONDS
  "$READY" "$PID" "$3" "$2" > "$OUT/$1-readiness.txt" 2>&1; return $?
}
# --- expansion-10k x5
if launch expansion "$FIX/exp"; then
  ready expansion "$FIX/exp" 90; rs=$?
  if [ "$rs" != 0 ]; then part expansion-10k INCOMPLETE "readiness probe exit $rs (rc 3 = AX trust unavailable)"
  else
    "$BENCH" expansion "$PID" "$OUT/expansion-10k.jsonl" expansion-10000 5 > "$OUT/expansion-10k.log" 2>&1; bs=$?
    [ "$bs" = 0 ] && part expansion-10k PASS "5 reps measured, bench exit 0" || part expansion-10k FAIL "bench exit $bs"
  fi; finish
else part expansion-10k INCOMPLETE "app launch failed"; fi
# --- typing 200 keys on 200k, then hover 60 sweeps, same instance
if launch typing "$FIX/typing/typing-200k"; then
  ready typing "$FIX/typing/typing-200k" 180; rs=$?
  if [ "$rs" != 0 ]; then part typing-200k INCOMPLETE "readiness probe exit $rs"; part hover INCOMPLETE "readiness probe exit $rs"
  else
    "$BENCH" typing "$PID" "$OUT/typing-200k.jsonl" 200 > "$OUT/typing-200k.log" 2>&1; ts=$?
    [ "$ts" = 0 ] && part typing-200k PASS "200 keys measured, bench exit 0" || part typing-200k FAIL "bench exit $ts"
    kill -0 "$PID" 2>/dev/null || part app-alive-after-typing FAIL "app process gone"
    "$BENCH" hover "$PID" "$OUT/hover.jsonl" 60 > "$OUT/hover.log" 2>&1; hs=$?
    [ "$hs" = 0 ] && part hover PASS "60 sweeps measured, bench exit 0" || part hover FAIL "bench exit $hs"
  fi
  if kill -0 "$PID" 2>/dev/null; then part app-alive PASS "same app process alive after the whole session"; else part app-alive FAIL "app process exited during the session"; fi
  finish
else part typing-200k INCOMPLETE "app launch failed"; part hover INCOMPLETE "app launch failed"; fi
# --- engine rescan plateau (engine process only), 60 scans, median windows of 15, 5%
python3 "$SD/perf2-soak.py" --spz "$SPZ" --root "$FIX/typing/typing-200k" --reps 60 --window 15 --out "$OUT/soak" > "$OUT/soak.log" 2>&1
sv=$(head -1 "$OUT/soak/soak-verdict.txt" 2>/dev/null); sd=$(grep -m1 median "$OUT/soak/soak-verdict.txt" 2>/dev/null)
part engine-plateau "${sv:-INCOMPLETE}" "${sd:-no soak verdict written}"
# --- crash reports created during this leg
crash_after=$(ls ~/Library/Logs/DiagnosticReports/Spacelyzer*.ips 2>/dev/null | wc -l | tr -d ' ')
mkdir -p "$OUT/crash"; [ "$crash_after" != "$crash_before" ] && cp ~/Library/Logs/DiagnosticReports/Spacelyzer*.ips "$OUT/crash/" 2>/dev/null
[ "$crash_after" = "$crash_before" ] && part no-new-crash-report PASS "none created" || part no-new-crash-report FAIL "$crash_before -> $crash_after Spacelyzer crash reports"
# --- app RSS series: informational
for f in "$OUT"/app-rss-*.txt; do [ -f "$f" ] && echo "$(basename "$f"): $(awk 'NR>1{if(!a)a=$2;b=$2;if($2>m)m=$2}END{print "samples="NR-1" first_kb="a" last_kb="b" max_kb="m}' "$f")" >> "$OUT/app-rss-summary.txt"; done
# --- verdict
v=PASS; while read -r name status rest; do [ "$status" = PASS ] || v=FAIL; done < "$OUT/parts.txt"
grep -q ' INCOMPLETE ' "$OUT/parts.txt" && [ "$v" = FAIL ] && ! grep -q ' FAIL ' "$OUT/parts.txt" && v=INCOMPLETE
{ echo "$v"; cat "$OUT/parts.txt"; echo "app RSS (informational, not gated):"; cat "$OUT/app-rss-summary.txt" 2>/dev/null; } > "$OUT/verdict.txt"
exit 0
