#!/bin/bash
# Typing-only leg (follow-up run). Usage: perf2-typing.sh APP FIXDIR OUT SCRIPTS_DIR BENCH READINESS
# Same launch, readiness and bench call as the typing part of perf2-stability.sh. The bench dumps every footer candidate on a non-unique match (see m3-interaction-bench.swift).
# Verdict: PASS only if the bench exits 0 (200 keys measured) and the app is still alive; INCOMPLETE if readiness fails; FAIL otherwise. No latency threshold.
set +e
APP="$1"; FIX="$2"; OUT="$3"; SD="$4"; BENCH="$5"; READY="$6"
mkdir -p "$OUT"; : > "$OUT/parts.txt"
part() { echo "$1 $2 $3" >> "$OUT/parts.txt"; echo "part $1: $2 $3"; }
crash_before=$(ls ~/Library/Logs/DiagnosticReports/Spacelyzer*.ips 2>/dev/null | wc -l | tr -d ' ')
ROOT="$FIX/typing/typing-200k"; PID=""
if pgrep -x Spacelyzer >/dev/null; then part typing-200k INCOMPLETE "Spacelyzer already running before launch"
else
  rm -f /tmp/spz-timing.txt
  open -n "$APP" --env SPZ_AUTOSCAN="$ROOT" --env SPZ_TIMING=1
  for i in $(seq 1 30); do n=$(pgrep -x Spacelyzer | wc -l | tr -d ' '); [ "$n" = "1" ] && { PID=$(pgrep -x Spacelyzer); break; }; sleep 1; done
  if [ -z "$PID" ]; then part typing-200k INCOMPLETE "app did not launch uniquely"
  else
    python3 "$SD/perf2-rss.py" "$PID" "$OUT/app-rss-typing.txt" & RSSPID=$!
    "$READY" "$PID" 180 "$ROOT" > "$OUT/typing-readiness.txt" 2>&1; rs=$?
    if [ "$rs" != 0 ]; then part typing-200k INCOMPLETE "readiness probe exit $rs (rc 3 = AX trust unavailable)"
    else
      "$BENCH" typing "$PID" "$OUT/typing-200k.jsonl" 200 > "$OUT/typing-200k.log" 2>&1; ts=$?
      [ "$ts" = 0 ] && part typing-200k PASS "bench exit 0 (200 keys measured)" || part typing-200k FAIL "bench exit $ts"
    fi
    if kill -0 "$PID" 2>/dev/null; then part app-alive PASS "app process alive after typing"; else part app-alive FAIL "app process exited"; fi
    kill "$PID" 2>/dev/null; sleep 1; kill -9 "$PID" 2>/dev/null; kill "$RSSPID" 2>/dev/null; wait "$RSSPID" 2>/dev/null
  fi
fi
crash_after=$(ls ~/Library/Logs/DiagnosticReports/Spacelyzer*.ips 2>/dev/null | wc -l | tr -d ' ')
mkdir -p "$OUT/crash"; [ "$crash_after" != "$crash_before" ] && cp ~/Library/Logs/DiagnosticReports/Spacelyzer*.ips "$OUT/crash/" 2>/dev/null
[ "$crash_after" = "$crash_before" ] && part no-new-crash-report PASS "none created" || part no-new-crash-report FAIL "$crash_before -> $crash_after crash reports"
for need in typing-200k app-alive no-new-crash-report; do
  c=$(awk -v n="$need" '$1==n' "$OUT/parts.txt" | wc -l | tr -d ' ')
  [ "$c" = 1 ] || echo "$need REQUIREMENT-VIOLATION appears $c times" >> "$OUT/parts.txt"
done
v=PASS; while read -r name status rest; do [ "$status" = PASS ] || v=FAIL; done < "$OUT/parts.txt"
grep -q ' FAIL ' "$OUT/parts.txt" || grep -q 'REQUIREMENT-VIOLATION' "$OUT/parts.txt" || { [ "$v" = FAIL ] && v=INCOMPLETE; }
grep -q 'REQUIREMENT-VIOLATION' "$OUT/parts.txt" && [ "$v" = PASS ] && v=INCOMPLETE
{ echo "$v"; cat "$OUT/parts.txt"; } > "$OUT/verdict.txt"
exit 0
