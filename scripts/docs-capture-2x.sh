#!/bin/bash
# Experimental: render-derived 2x docs captures from the TEST-ONLY app (needs SPZ_CI_TESTS; the shipped app has no such code).
# Same states and order as the real 1x docs captures in ci.yml, which stay unchanged. Output: dist/screenshot-docs-2x-render-<name>.png
# plus a .txt per image saying how it was made. Never a native Retina capture; inspect every image against its 1x counterpart.
# Usage: docs-capture-2x.sh <path to test-only Spacelyzer.app> <sample dir>
set +e
APP="${1:?app}"; SAMPLE="${2:?sample dir}"; HELPER=/tmp/spz-docs-capture
SHOTS=$(mktemp -d); mkdir -p dist
[ -x "$HELPER" ] || swiftc scripts/docs-capture.swift -o "$HELPER"
launch() { pkill Spacelyzer; sleep 2; open -n "$APP" --env SPZ_WINDOW_SIZE=960x600 --env SPZ_SHOT_DIR="$SHOTS" "$@"; sleep 6
  PID=$(pgrep -n -f "$APP/Contents/MacOS/Spacelyzer"); echo "launched pid=$PID"; }
cap() {   # cap <name>: ask the app for a render, wait for its png or failure note
  touch "$SHOTS/$1.req"
  for _ in $(seq 1 50); do [ -s "$SHOTS/$1.png" ] || grep -q FAILED "$SHOTS/$1.txt" 2>/dev/null && break; sleep 0.2; done
  if [ -s "$SHOTS/$1.png" ]; then cp "$SHOTS/$1.png" "dist/screenshot-docs-2x-render-$1.png"; cp "$SHOTS/$1.txt" "dist/screenshot-docs-2x-render-$1.txt"; head -2 "$SHOTS/$1.txt"
  else echo "2x render failed or timed out: $1 ($(cat "$SHOTS/$1.txt" 2>/dev/null))"; fi; }
launch --env SPZ_AUTOSCAN="$SAMPLE"
sleep 12
cap overview
"$HELPER" "$PID" press Kinds && sleep 2 && cap kinds
"$HELPER" "$PID" press Largest && sleep 2 && cap largest
"$HELPER" "$PID" select 0 && sleep 1 && "$HELPER" "$PID" press "Check on disk" && sleep 3 && cap review
"$HELPER" "$PID" escape; sleep 1
"$HELPER" "$PID" press Folders && sleep 2 && cap folders
"$HELPER" "$PID" press Largest && sleep 1
"$HELPER" "$PID" type pdf && sleep 2 && cap filtered-largest
"$HELPER" "$PID" type zzz && sleep 2 && cap no-matches
launch --env SPZ_AUTOSCAN="$SAMPLE" --env SPZ_DEMO_APPEARANCE=dark
sleep 12
cap overview-dark
launch
sleep 2
cap welcome
launch --env SPZ_DEMO_APPEARANCE=dark
sleep 2
cap welcome-dark
launch --env SPZ_DEMO_FDA_REFUSED=1 --env SPZ_AUTOSCAN="$SAMPLE"
sleep 12
cap fda-banner
pkill Spacelyzer; sleep 2
ls -l dist/screenshot-docs-2x-render-*.png || echo "no 2x renders"
