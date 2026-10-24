#!/bin/bash
# Called only after compact history proof/dismissal, same process and session.
# Parent bounds this entire stage to20s; no product mutation except window size.
set -e
HELPER="${1:?helper}"; PID="${2:?pid}"; OUT="${3:?out}"; BOUND="${4:?bound}"
ax() { python3 "$BOUND" 4 "$HELPER" "$PID" "$@"; }
ax nosheet
ax resize 1280 800 > "$OUT/history-wide-resize.txt"
# Resize success requires actual window dimensions in the helper, not intent.
ax snapshot > "$OUT/v1-snapshot-history-wide-before.txt"
if ! ax press "Removal history"; then
  ax choose "more toolbar items" "Removed"
fi
[ -n "${V1_FAST:-}" ] || sleep 1
# Exact session entry must be inside the actual foreground popover, never row/model.
ax sheettext "Backup 2025.zip" > "$OUT/history-wide-content.txt"
ax snapshot > "$OUT/v1-snapshot-history-wide-live.txt"
r=$(ax rect)
screencapture -x -R "$r" "$OUT/screenshot-v1-removal-history-wide.png"
[ -s "$OUT/screenshot-v1-removal-history-wide.png" ]
ax escape
