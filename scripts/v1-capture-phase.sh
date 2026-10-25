#!/bin/bash
# v1 window-only cleanup captures on a disposable sample tree (informational evidence; real captures, no mocks).
# Usage: v1-capture.sh <app> <out dir>. Drives the real app through ordinary accessibility presses. Never touches
# anything outside the disposable $HOME/Sample copy: the only removal is ONE sample file moved to the Trash through
# the app's own confirmation. Each shot is independent: a failed shot is recorded in STATUS and the flow continues.
# Overrides for the Linux preflight (stubs): HELPER, SAMPLE, BOUND.
set +e
APP="${1:?app}"; OUT="${2:?out dir}"
HELPER="${HELPER:-/tmp/spz-docs-capture}"; SAMPLE="${SAMPLE:-$HOME/Sample}"; BOUND="${BOUND:-scripts/run-bounded.py}"
STATUS="$OUT/v1-phase-${V1_PHASE:?phase}-status.txt"; mkdir -p "$OUT"; : > "$STATUS"
nap() { [ -n "${V1_FAST:-}" ] || sleep "$1"; }
note() { echo "$*" | tee -a "$STATUS"; }
AX_SEQ=0
ax() {
  # One exact invocation record per action/read. Keep stdout unchanged for rect
  # and frame parsers, while retaining errors even when caller redirects them.
  local stem rc
  AX_SEQ=$((AX_SEQ + 1))
  stem=$(mktemp "$OUT/action-$V1_PHASE-XXXXXX")
  rm -f "$stem"
  printf '%s\n' "$HELPER" "$PID" "$@" > "$stem-argv.txt"
  python3 "$BOUND" 8 "$HELPER" "$PID" "$@" > "$stem-stdout.txt" 2> "$stem-stderr.txt"
  rc=$?
  printf '%s\n' "$rc" > "$stem-rc.txt"
  cat "$stem-stdout.txt"
  cat "$stem-stderr.txt" >&2
  return "$rc"
}
PID=""
START="${V1_STARTED:-$(date +%s)}"; BUDGET="${V1_BUDGET:-165}"
over() { [ $(( $(date +%s) - START )) -gt "$BUDGET" ]; }
shot() {   # shot <name>: capture the union of the app's windows (main window plus any sheet, alert or popover)
  local r; r=$(ax rect) || { note "FAIL $1 rect: $r"; return 1; }
  screencapture -x -R "$r" "$OUT/screenshot-v1-$1.png" && [ -s "$OUT/screenshot-v1-$1.png" ] && note "OK $1 rect=$r" || { note "FAIL $1 screencapture rect=$r"; return 1; }
}
diag() { ax dump > "$OUT/v1-dump-$1.txt" 2>&1; ax snapshot > "$OUT/v1-snapshot-$1.txt" 2>&1; }
# snap <stage>: bounded full-attribute AX snapshot WHILE the surface is live (before dismissal), so one Mac contact
# settles the SDK/AX unknowns (scope identity, AXSelected semantics, parent chains) whether the flow passes or fails.
snap() { note "SNAPSHOT $1"; ax snapshot > "$OUT/v1-snapshot-$1.txt" 2>&1; }
step() {   # step <shot name> <command...>: run an AX command; on failure keep a diagnostic tree dump
  local n="$1"; shift
  "$@" || { note "STEP-FAIL $n: $*"; diag "$n"; return 1; }
}

case "$V1_PHASE" in
prepare)
if [ ! -x "$HELPER" ]; then python3 "$BOUND" 120 swiftc scripts/docs-capture.swift -o "$HELPER" || { note "FAIL helper compile"; exit 1; }; fi
bash scripts/make-docs-fixture.sh "$SAMPLE" >/dev/null 2>&1 || { note "FAIL fixture"; exit 1; }
# This script's own copy gets one explicit, non-zero duplicate pair so the duplicates shot shows a real review, not the
# empty state (the shared fixture generator and the published image counts are untouched).
mkdir -p "$SAMPLE/Documents/Reports" "$SAMPLE/Downloads"
yes 'sample duplicate content' | head -c 7340032 > "$SAMPLE/Documents/Reports/Annual Summary.pdf"
cp "$SAMPLE/Documents/Reports/Annual Summary.pdf" "$SAMPLE/Downloads/Annual Summary (1).pdf" || { note "FAIL duplicate pair"; exit 1; }
;;
exclusions)
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
  if [ "$excl_ok" -eq 1 ]; then snap exclusions-live; nap 1; shot exclusions; else note "STEP-FAIL exclusions-content: the Exclusions sheet's own text was not observed"; diag exclusions-content; fi
  ax escape; nap 1
fi
;;
duplicates)
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

# 2. Duplicates review: wait for the real result, not a fixed delay.
if over; then note "SKIPPED duplicates: time budget"; elif step duplicates ax choose Scan "Duplicates…"; then
  dup_ok=0
  for _ in $(seq 1 45); do ax sheettext "groups ·" >/dev/null 2>&1 && { dup_ok=1; break; }; ax sheettext "No duplicate files found" >/dev/null 2>&1 && { dup_ok=1; break; }; nap 1; done   # the sheet's own content, not background chrome
  # The wait is a GATE: markers that never appear mean no shot (missing readiness never counts as OK).
  if [ "$dup_ok" -eq 1 ]; then snap duplicates-live; nap 1; shot duplicates; else note "STEP-FAIL duplicates-content: neither the groups summary nor the empty state appeared in the Duplicates sheet"; diag duplicates-content; fi
  ax escape; nap 1
fi
;;
cleanup)
# 3. Cleanup flow on ONE sample file: confirmation, result alert, removal history. Never confirms without the alert showing.
# The target is selected BY NAME (Backup 2025.zip, the fixture's largest file): "select row 0 of the first table" is the
# outline's largest FOLDER (run 39947043378 trashed the whole Archives folder instead of one file).
# Back to 960x600 (the docs size for this flow; the FDA layout check is defined at 960x600).
pkill Spacelyzer; nap 2
open -n "$APP" --env SPZ_WINDOW_SIZE=960x600 --env SPZ_SIZE_REQUESTS=1 --env SPZ_AUTOSCAN="$SAMPLE"
for _ in $(seq 1 10); do PID=$(pgrep -n -f "$APP/Contents/MacOS/Spacelyzer"); [ -n "$PID" ] && break; nap 1; done
[ -n "$PID" ] || { note "FAIL app did not relaunch for the Trash flow"; exit 1; }
for _ in $(seq 1 30); do ax hastext " items" >/dev/null 2>&1 && break; nap 1; done
nap 2
ax press Largest; nap 2
if over; then note "SKIPPED trash flow: time budget"; elif step select ax selectrow "Backup 2025.zip" && snap select-target && nap 1 && step trash-open ax press "Move selected item to Trash"; then
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
    snap trash-confirm-live
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
      snap trash-after-press
      confirmed=0
      for _ in $(seq 1 10); do ax sheettext "Moved Backup 2025.zip" >/dev/null 2>&1 && { confirmed=1; break; }; nap 1; done
      if [ "$confirmed" -eq 1 ]; then
        [ "$press_rc" -eq 1 ] && note "trash-confirm-press outcome verified after AXPress error (result dialog names the target)"
        snap trash-result-live; nap 2
        # Escape did not dismiss this alert in run40022177880. Press the observed OK
        # button once, then require the result dialog to disappear before either done or history capture.
        ax press OK; nap 1
        dismissed=0
        for _ in $(seq 1 5); do
          ax nosheet >/dev/null 2>&1 && { dismissed=1; break; }
          nap 1
        done
        if [ "$dismissed" -ne 1 ]; then
          note "STEP-FAIL result-dismiss: result dismissal not observed (panel present or AX unreadable); done/history not captured"; diag result-dismiss
        else
          snap trash-dismissed-live
          # Native footer gate (run 40194081483: the footer stayed at "118 items" after the removal while the bytes dropped).
          # Compare the footer item count in the pre-dialog snapshot with the post-removal one: exactly one file was removed.
          # Anchored to the status line: a byte-size token then "in N items" (no other element matches that shape).
          fc() { grep -oE '[0-9][0-9.,]* ?(B|KB|MB|GB|TB|bytes?) in [0-9][0-9,]* items?' "$1" 2>/dev/null | head -1 | grep -oE '[0-9][0-9,]* items?$' | tr -dc '0-9'; }
          fc_before=$(fc "$OUT/v1-snapshot-select-target.txt"); fc_after=$(fc "$OUT/v1-snapshot-trash-dismissed-live.txt")
          # A late re-render may land just after the dialog closes: re-read up to 4 times (about 2s) until the count settles.
          for _ in 1 2 3 4; do
            { [ -n "$fc_before" ] && [ -n "$fc_after" ] && [ "$fc_after" -eq $((fc_before - 1)) ]; } && break
            nap 0.5; ax snapshot > "$OUT/v1-snapshot-footer-settle.txt" 2>&1; fc_after=$(fc "$OUT/v1-snapshot-footer-settle.txt")
          done
          if [ -n "$fc_before" ] && [ -n "$fc_after" ] && [ "$fc_after" -eq $((fc_before - 1)) ]; then note "footer-count OK: $fc_before -> $fc_after items after removing one file"
          else note "STEP-FAIL footer-count: footer item count before=${fc_before:-unreadable} after=${fc_after:-unreadable} (still wrong after settle re-reads), expected after=before-1"; fi
          shot trash-done
          # At960wide the button can be in the native toolbar overflow (retained AX snapshot).
          snap history-before-open
          if ! ax press "Removal history"; then
            snap history-direct-press-failed
            step history ax choose "more toolbar items" "Removed" || dismissed=0
          fi
          snap history-after-open
        fi
        # Removal history must show THIS removal's journal entry in the popover, not just open.
        if [ "$dismissed" -eq 1 ]; then
          hist_ok=0
          for _ in $(seq 1 10); do ax sheettext "Backup 2025.zip" >/dev/null 2>&1 && { hist_ok=1; break; }; nap 1; done
          if [ "$hist_ok" -eq 1 ]; then snap history-live; shot removal-history; else note "STEP-FAIL history-content: journal entry for Backup 2025.zip not observed in the history popover"; diag history-content; fi
          ax escape; nap 1
          if [ "$hist_ok" -eq 1 ]; then
            # Same PID/session/journal entry, no new removal. The entire added
            # wide stage has a 20s cap within the unchanged 165s v1 budget.
            if [ $(( $(date +%s) - START + 20 )) -gt "$BUDGET" ]; then
              note "STEP-FAIL history-wide: insufficient remaining original budget"
            elif python3 "$BOUND" 20 bash scripts/capture-history-wide.sh "$HELPER" "$PID" "$OUT" "$BOUND"; then
              note "WIDE-HISTORY OK: same-session 1280x800 actual entry captured"
            else
              note "STEP-FAIL history-wide: capture refused or timed out"
            fi
          fi
        fi
      else
        note "STEP-FAIL trash-result: result dialog naming Backup 2025.zip not observed after the confirm press (rc=$press_rc: $press_out)"; diag trash-result
      fi
    fi
  fi
fi

;;
fda)
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
  snap fda-live; shot fda-banner
else
  note "FAIL fda relaunch"
fi
pkill Spacelyzer; nap 2
;;
*) exit 2;;
esac
if grep -Eq '^(FAIL|STEP-FAIL|SKIPPED|FDA-LAYOUT (FAIL|UNKNOWN))' "$STATUS"; then exit 1; fi
exit 0
