#!/bin/bash
# soak.sh <engine-binary> <outdir> - bounded memory-soak measurement (measurement-only).
# In-process reps (spz bench) with external live-RSS sampling, plus separate-process peaks.
set -u
BIN="$1"; OUT="$2"; TARGET="${3:-/Library}"
mkdir -p "$OUT"
# 1) in-process soak: 15 reps of the same tree; bench prints per-rep walls + process HWM.
"$BIN" bench "$TARGET" 15 > "$OUT/bench15.log" 2>&1 &
BPID=$!
# live-RSS sampler at ~2 Hz while bench runs (ps rss in KB on macOS).
( while kill -0 "$BPID" 2>/dev/null; do ts=$(perl -MTime::HiRes=time -e 'printf "%.3f", time()'); ps -o pid=,rss=,vsz= -p "$BPID" | awk -v ts="$ts" '{print ts, $0}'; sleep 0.5; done ) > "$OUT/bench15.liverss.log" 2>/dev/null &
SPID=$!
wait "$BPID"; RC=$?
kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null
echo "bench-exit=$RC" >> "$OUT/bench15.log"
# 2) separate-process peaks: 10 fresh processes, per-process maxrss from /usr/bin/time -l.
: > "$OUT/separate10.log"
for i in $(seq 1 10); do
  /usr/bin/time -l "$BIN" scan "$TARGET" >> "$OUT/separate10.log" 2>&1
  echo "--- rep $i rc=$?" >> "$OUT/separate10.log"
done
