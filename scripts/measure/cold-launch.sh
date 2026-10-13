#!/bin/bash
# cold-launch.sh <app-path> <driver-binary> <outdir> - 3 cold opens, time-to-AX-window.
# Shared-runner ballpark only; no purge of disk cache attempted (informational).
set -u
APP="$1"; DRIVER="$2"; OUT="$3"
mkdir -p "$OUT"
pkill -x Spacelyzer 2>/dev/null; sleep 2
for i in 1 2 3; do
  START=$(python3 -c 'import time; print(time.time())')
  open -n "$APP"
  PID=""
  for j in $(seq 1 60); do PID=$(pgrep -x Spacelyzer | head -1); [ -n "$PID" ] && break; sleep 0.5; done
  if [ -z "$PID" ]; then echo "rep $i: no process" >> "$OUT/cold.log"; continue; fi
  T0=$(python3 -c 'import time; print(time.time())')
  if "$DRIVER" waitwindow "$PID" >/dev/null 2>&1; then RC=0; else RC=1; fi
  T1=$(python3 -c 'import time; print(time.time())')
  python3 -c "print(f'rep $i: open_to_pid={$T0-$START:.3f}s pid_to_window={$T1-$T0:.3f}s total={$T1-$START:.3f}s rc=$RC')" >> "$OUT/cold.log"
  pkill -x Spacelyzer; sleep 2
done
