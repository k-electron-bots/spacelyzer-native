#!/bin/bash
# diagnostic-watch.sh <app> <driver> <scan-root> <stall-log-dir> <out-dir> [watch-cap-s] [mode]
# One LABELED DIAGNOSTIC launch - never bar-compared, closes no gate (pre-registered
# instrumentation separation, see ci.yml header). The launch carries the bounded-ping-v1
# main-stall monitor (SPZ_STALL_MONITOR) with per-launch append+flush JSONL telemetry
# (SPZ_STALL_LOG_DIR); telemetry is copied into <out-dir> as labeled copies (cp -n never
# overwrites a prior launch). mode=watch (default): passive scan-window watch.
# mode=cancel: one instrumented cancel (same unmodified driver cancel path) + 30s post-cancel
# watch; comparability with the uninstrumented bar cycles is pre-declared uncertain.
# Bounded: the driver's own in-process watchdogs plus the caller's budgeted_run clip.
set -u
APP=$1; DRIVER=$2; ROOT=$3; LOGDIR=$4; OUT=$5; CAP=${6:-60}; MODE=${7:-watch}
kill_owned() {
  [ -n "$1" ] || return 0
  kill -TERM "$1" 2>/dev/null || true
  for k in $(seq 1 10); do kill -0 "$1" 2>/dev/null || break; sleep 0.5; done
  kill -0 "$1" 2>/dev/null && kill -KILL "$1" 2>/dev/null || true
}
mkdir -p "$LOGDIR" "$OUT"
echo "marker ts_ms=$(( $(date +%s)*1000 )) stage=diagnostic-launch mode=$MODE root=$ROOT cap=$CAP"
open -n "$APP" --env SPZ_AUTOSCAN="$ROOT" --env SPZ_STALL_MONITOR=1 --env SPZ_STALL_LOG_DIR="$LOGDIR"
PID=""
for i in $(seq 1 100); do PID=$(pgrep -x Spacelyzer | head -1); [ -n "$PID" ] && break; sleep 0.1; done
if [ -z "$PID" ]; then
  echo "{\"note\":\"diagnostic-no-process\",\"mode\":\"$MODE\"}" >> "$OUT/diagnostic-notes.jsonl"
  echo "marker ts_ms=$(( $(date +%s)*1000 )) stage=diagnostic-no-process"
  exit 1
fi
echo "marker ts_ms=$(( $(date +%s)*1000 )) stage=diagnostic-pid pid=$PID"
if ! "$DRIVER" waitwindow "$PID"; then
  echo "{\"note\":\"diagnostic-waitwindow-failed\",\"mode\":\"$MODE\",\"pid\":$PID}" >> "$OUT/diagnostic-notes.jsonl"
  kill_owned "$PID"
  exit 1
fi
RC=0
if [ "$MODE" = "cancel" ]; then
  "$DRIVER" cancel "$PID" "$OUT/diagnostic-cancel-$PID.jsonl" || RC=$?
  echo "marker ts_ms=$(( $(date +%s)*1000 )) stage=diagnostic-cancel-done rc=$RC"
  "$DRIVER" watch "$PID" "$OUT/diagnostic-post-cancel-watch-$PID.jsonl" 30 || true
else
  "$DRIVER" watch "$PID" "$OUT/diagnostic-watch-$PID.jsonl" "$CAP" || RC=$?
fi
echo "marker ts_ms=$(( $(date +%s)*1000 )) stage=diagnostic-watch-done rc=$RC mode=$MODE"
kill_owned "$PID"
echo "marker ts_ms=$(( $(date +%s)*1000 )) stage=diagnostic-cleanup-done"
# Per-launch unique app telemetry -> labeled copies (originals stay in the log dir).
cp -np "$LOGDIR"/spz-stall-*.jsonl "$OUT"/ 2>/dev/null || true
exit 0
