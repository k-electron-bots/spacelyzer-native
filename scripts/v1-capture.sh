#!/bin/bash
# v1 window-only cleanup captures on a disposable sample tree (informational evidence; real captures, no mocks).
# Usage: v1-capture.sh <app> <out dir>. Drives the real app through ordinary accessibility presses. Never touches
# anything outside the disposable $HOME/Sample copy: the only removal is ONE sample file moved to the Trash through
# the app's own confirmation. Each shot is independent: a failed shot is recorded in STATUS and the flow continues.
# Overrides for the Linux preflight (stubs): HELPER, SAMPLE, BOUND.
set +e
APP="${1:?app}"; OUT="${2:?out dir}"
HELPER="${HELPER:-/tmp/spz-docs-capture}"; SAMPLE="${SAMPLE:-$HOME/Sample}"; BOUND="${BOUND:-scripts/run-bounded.py}"
STATUS="$OUT/v1-capture-status.txt"; mkdir -p "$OUT"; : > "$STATUS"
nap() { [ -n "${V1_FAST:-}" ] || sleep "$1"; }
note() { echo "$*" | tee -a "$STATUS"; }
ax() { python3 "$BOUND" 8 "$HELPER" "$PID" "$@"; }
PID=""
START=$(date +%s); BUDGET="${V1_BUDGET:-165}"
over() { [ $(( $(date +%s) - START )) -gt "$BUDGET" ]; }
shot() {   # shot <name>: capture the union of the app's windows (main window plus any sheet, alert or popover)
  local r; r=$(ax rect) || { note "FAIL $1 rect: $r"; return 1; }
  screencapture -x -R "$r" "$OUT/screenshot-v1-$1.png" && [ -s "$OUT/screenshot-v1-$1.png" ] && note "OK $1 rect=$r" || { note "FAIL $1 screencapture rect=$r"; return 1; }
}
diag() { ax dump > "$OUT/v1-dump-$1.txt" 2>&1; }
step() {   # step <shot name> <command...>: run an AX command; on failure keep a diagnostic tree dump
  local n="$1"; shift
  "$@" || { note "STEP-FAIL $n: $*"; diag "$n"; return 1; }
}
if [ ! -x "$HELPER" ]; then python3 "$BOUND" 120 swiftc scripts/docs-capture.swift -o "$HELPER" || { note "FAIL helper compile"; exit 1; }; fi
bash scripts/make-docs-fixture.sh "$SAMPLE" >/dev/null 2>&1 || { note "FAIL fixture"; exit 1; }
# This script's own copy gets one explicit, non-zero duplicate pair so the duplicates shot shows a real review, not the
# empty state (the shared fixture generator and the published image counts are untouched).
mkdir -p "$SAMPLE/Documents/Reports" "$SAMPLE/Downloads"
yes 'sample duplicate content' | head -c 7340032 > "$SAMPLE/Documents/Reports/Annual Summary.pdf"
cp "$SAMPLE/Documents/Reports/Annual Summary.pdf" "$SAMPLE/Downloads/Annual Summary (1).pdf" || { note "FAIL duplicate pair"; exit 1; }
pkill Spacelyzer; nap 2
# Exclusions and Duplicates open from the toolbar's Scan menu. At 960x600 the toolbar collapses that menu into the
# "more toolbar items" overflow (run 39947043378 AX dump), so these two sections use a 1280x800 instance.
open -n "$APP" --env SPZ_WINDOW_SIZE=1280x800 --env SPZ_AUTOSCAN="$SAMPLE"
for _ in $(seq 1 10); do PID=$(pgrep -n -f "$APP/Contents/MacOS/Spacelyzer"); [ -n "$PID" ] && break; nap 1; done
[ -n "$PID" ] || { note "FAIL app did not launch"; exit 1; }
note "launched pid=$PID app=$APP"
# Scan finished when the footer shows an item count.
for _ in $(seq 1 30); do ax hastext " items" >/dev/null 2>&1 && break; nap 1; done
nap 2

# 1. Exclusions sheet (opens only; nothing is added). The shot counts only when the sheet's OWN content is observed:
# a successful menu press is not proof the sheet opened with content.
if step exclusions ax choose Scan "Exclusions…"; then
  excl_ok=0
  for _ in $(seq 1 10); do ax sheettext "Scans skip these locations" >/dev/null 2>&1 && { excl_ok=1; break; }; nap 1; done
  if [ "$excl_ok" -eq 1 ]; then nap 1; shot exclusions; else note "STEP-FAIL exclusions-content: the Exclusions sheet's own text was not observed"; diag exclusions-content; fi
  ax escape; nap 1
fi
# 2. Duplicates review: wait for the real result, not a fixed delay.
if over; then note "SKIPPED duplicates: time budget"; elif step duplicates ax choose Scan "Duplicates…"; then
  dup_ok=0
  for _ in $(seq 1 45); do ax sheettext "groups ·" >/dev/null 2>&1 && { dup_ok=1; break; }; ax sheettext "No duplicate files found" >/dev/null 2>&1 && { dup_ok=1; break; }; nap 1; done   # the sheet's own content, not background chrome
  # The wait is a GATE: markers that never appear mean no shot (missing readiness never counts as OK).
  if [ "$dup_ok" -eq 1 ]; then nap 1; shot duplicates; else note "STEP-FAIL duplicates-content: neither the groups summary nor the empty state appeared in the Duplicates sheet"; diag duplicates-content; fi
  ax escape; nap 1
fi
# 3. Cleanup flow on ONE sample file: confirmation, result alert, removal history. Never confirms without the alert showing.
# The target is selected BY NAME (Backup 2025.zip, the fixture's largest file): "select row 0 of the first table" is the
# outline's largest FOLDER (run 39947043378 trashed the whole Archives folder instead of one file).
# Back to 960x600 (the docs size for this flow; the FDA layout check is defined at 960x600).
pkill Spacelyzer; nap 2
open -n "$APP" --env SPZ_WINDOW_SIZE=960x600 --env SPZ_AUTOSCAN="$SAMPLE"
for _ in $(seq 1 10); do PID=$(pgrep -n -f "$APP/Contents/MacOS/Spacelyzer"); [ -n "$PID" ] && break; nap 1; done
[ -n "$PID" ] || { note "FAIL app did not relaunch for the Trash flow"; exit 1; }
for _ in $(seq 1 30); do ax hastext " items" >/dev/null 2>&1 && break; nap 1; done
nap 2
ax press Largest; nap 2
if over; then note "SKIPPED trash flow: time budget"; elif step select ax selectrow "Backup 2025.zip" && nap 1 && step trash-open ax press "Move selected item to Trash"; then
  nap 2
  if ! ax sheettext "Move to Trash?" >/dev/null 2>&1; then   # the CONFIRMATION'S OWN title, never the background window
    note "FAIL trash-confirm: alert text not present; nothing was confirmed"; diag trash-confirm
  elif ! ax sheettext "$SAMPLE/Archives/Backup 2025.zip" >/dev/null 2>&1; then   # must be named BY THE DIALOG: the background Largest row carries the same path and must not launder the check
    # Scope guard: the confirmation must name the OWNED FIXTURE FILE BY ITS FULL SCANNED PATH ($SAMPLE is the
    # disposable fixture root we passed to SPZ_AUTOSCAN, so this is exactly the path the app displays for it).
    # A same-named file anywhere else, a folder, or another item is refused without confirming
    # (run 39947043378 confirmed the Archives FOLDER).
    note "FAIL trash-scope: confirmation does not name the fixture file $SAMPLE/Archives/Backup 2025.zip; nothing confirmed"; diag trash-scope; ax escape; nap 1
  else
    shot trash-confirm
    # The confirm is proven by its OUTCOME on BOTH press paths: a returned error can follow a DELIVERED press (the
    # alert dismisses itself mid-action - run 39947043378: "press failed: Move to Trash" 63 ms after the shot), and a
    # "successful" return is not proof the result appeared. Only "not found" is a genuine missing button.
    # The postcondition is the fresh RESULT dialog naming the exact target ("Moved Backup 2025.zip to the Trash.");
    # a stale or unrelated result alert cannot satisfy it. Never a blind re-press.
    press_rc=0; press_out=$(ax press "Move to Trash" 2>&1) || press_rc=1
    if [ "$press_rc" -eq 1 ] && [[ "$press_out" == *"not found"* ]]; then
      note "STEP-FAIL trash-confirm-press: $press_out"; diag trash-confirm-press
    else
      confirmed=0
      for _ in $(seq 1 10); do ax sheettext "Moved Backup 2025.zip" >/dev/null 2>&1 && { confirmed=1; break; }; nap 1; done
      if [ "$confirmed" -eq 1 ]; then
        [ "$press_rc" -eq 1 ] && note "trash-confirm-press outcome verified after AXPress error (result dialog names the target)"
        nap 2; shot trash-done
        ax escape; nap 1
        # Removal history must show THIS removal's journal entry in the popover, not just open.
        if step history ax press "Removal history"; then
          hist_ok=0
          for _ in $(seq 1 10); do ax sheettext "Backup 2025.zip" >/dev/null 2>&1 && { hist_ok=1; break; }; nap 1; done
          if [ "$hist_ok" -eq 1 ]; then shot removal-history; else note "STEP-FAIL history-content: journal entry for Backup 2025.zip not observed in the history popover"; diag history-content; fi
          ax escape; nap 1
        fi
      else
        note "STEP-FAIL trash-result: result dialog naming Backup 2025.zip not observed after the confirm press (rc=$press_rc: $press_out)"; diag trash-result
      fi
    fi
  fi
fi

# 4. FDA banner state (SPZ_DEMO_FDA_REFUSED can only refuse). Besides the pixels, check by accessibility frames that the
# filter field and the treemap pane header start BELOW the banner (the pre-fix layout put the banner over them).
pkill Spacelyzer; nap 2
open -n "$APP" --env SPZ_WINDOW_SIZE=960x600 --env SPZ_DEMO_FDA_REFUSED=1 --env SPZ_AUTOSCAN="$SAMPLE"
for _ in $(seq 1 10); do PID=$(pgrep -n -f "$APP/Contents/MacOS/Spacelyzer"); [ -n "$PID" ] && break; nap 1; done
if over; then note "SKIPPED fda-banner: time budget"
elif [ -n "$PID" ]; then
  for _ in $(seq 1 30); do ax hastext " items" >/dev/null 2>&1 && break; nap 1; done
  nap 3
  bf=$(ax frame "Open System Settings"); ff=$(ax frame "Filter by name")
  note "fda frames: banner-button=[$bf] filter-field=[$ff]"
  python3 - "$bf" "$ff" >> "$STATUS" <<'PY'
import sys
try:
    b = [int(v) for v in sys.argv[1].split(",")]; f = [int(v) for v in sys.argv[2].split(",")]
    print("FDA-LAYOUT %s: filter field top %d vs banner button bottom %d" % ("OK" if f[1] >= b[1] + b[3] else "FAIL (field is under the banner)", f[1], b[1] + b[3]))
except Exception as e:
    print("FDA-LAYOUT UNKNOWN: frames unavailable (%s)" % e)
PY
  shot fda-banner
else
  note "FAIL fda relaunch"
fi
pkill Spacelyzer; nap 2
note "done"
# Fail closed: anything but 6 captured shots with an OK layout verdict is an incomplete validation, never green.
oks=$(grep -c '^OK ' "$STATUS")
if [ "$oks" -ne 6 ] || grep -Eq '^(FAIL|STEP-FAIL|SKIPPED|FDA-LAYOUT (FAIL|UNKNOWN))' "$STATUS" || ! grep -q '^FDA-LAYOUT OK' "$STATUS"; then
  note "V1-CAPTURE INCOMPLETE: $oks of 6 shots OK; see FAIL/STEP-FAIL/SKIPPED/FDA-LAYOUT lines (not a pass, not docs-complete)"; exit 1
fi
note "V1-CAPTURE COMPLETE: 6 of 6 shots and FDA-LAYOUT OK; pixels still need review before any publication"
