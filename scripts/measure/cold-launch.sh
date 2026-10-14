#!/bin/bash
# cold-launch.sh <app-path> <driver-binary> <outdir> - 3 cold opens, time-to-AX-window.
# Shared-runner ballpark only; no purge of disk cache attempted (informational).
# Bounded like the main measurement steps: owned-PID TERM->KILL cleanup (never name-based pkill),
# external watchdog around the driver waitwindow call, epoch-ms markers per stage.
set -u
APP="$1"; DRIVER="$2"; OUT="$3"
mkdir -p "$OUT"

kill_owned() {
  [ -n "$1" ] || return 0
  kill -TERM "$1" 2>/dev/null || true
  for k in $(seq 1 10); do kill -0 "$1" 2>/dev/null || break; sleep 0.5; done
  kill -0 "$1" 2>/dev/null && kill -KILL "$1" 2>/dev/null || true
}

run_bounded() {
  local limit=$1; shift
  local flag; flag=$(mktemp "${TMPDIR:-/tmp}/spzwatch.XXXXXX")
  "$@" & local cpid=$!
  ( i=0; while [ "$i" -lt "$limit" ]; do sleep 1; i=$((i+1)); done
    echo 1 > "$flag"
    kill -TERM "$cpid" 2>/dev/null
    i=0; while [ "$i" -lt 15 ]; do sleep 1; kill -0 "$cpid" 2>/dev/null || break; i=$((i+1)); done
    kill -KILL "$cpid" 2>/dev/null ) & local wpid=$!
  local rc=0
  wait "$cpid" || rc=$?
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  if [ -s "$flag" ]; then echo "WATCHDOG-EXTERNAL timeout_s=$limit cmd=$1"; rc=124; fi
  rm -f "$flag"
  return "$rc"
}

marker() { echo "marker ts_ms=$(( $(date +%s) * 1000 )) stage=$1"; }

# Pre-clean: any leftover instances from earlier steps (they clean their own PID; this is a
# backstop) get PID-specific TERM->KILL, never name-based pkill.
for P in $(pgrep -x Spacelyzer 2>/dev/null); do kill_owned "$P"; done
sleep 1

for i in 1 2 3; do
  marker "cold-rep-$i-launch"
  START=$(python3 -c 'import time; print(time.time())')
  open -n "$APP"
  PID=""
  for j in $(seq 1 60); do PID=$(pgrep -x Spacelyzer | head -1); [ -n "$PID" ] && break; sleep 0.5; done
  if [ -z "$PID" ]; then echo "rep $i: no process" >> "$OUT/cold.log"; continue; fi
  marker "cold-rep-$i-pid pid=$PID"
  T0=$(python3 -c 'import time; print(time.time())')
  RC=0
  run_bounded 270 "$DRIVER" waitwindow "$PID" >/dev/null 2>&1 || RC=$?
  T1=$(python3 -c 'import time; print(time.time())')
  python3 -c "print(f'rep $i: open_to_pid={$T0-$START:.3f}s pid_to_window={$T1-$T0:.3f}s total={$T1-$START:.3f}s rc=$RC')" >> "$OUT/cold.log"
  kill_owned "$PID"
  marker "cold-rep-$i-cleanup-done rc=$RC"
  if [ "$RC" -eq 124 ]; then
    echo "rep $i: external watchdog timeout - remaining reps aborted" >> "$OUT/cold.log"
    marker "cold-reps-aborted-first-timeout"
    break
  fi
done
