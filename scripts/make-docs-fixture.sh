#!/bin/bash
# Builds a small, friendly sample tree for documentation captures. Zero-filled files with plausible names and
# extensions; nothing here is real user data. Usage: make-docs-fixture.sh <dest> (created fresh).
set -euo pipefail
dest="$1"
rm -rf "$dest"; mkdir -p "$dest"
f() { local mb="$1" path="$dest/$2"; mkdir -p "$(dirname "$path")"; dd if=/dev/zero of="$path" bs=1048576 count="$mb" 2>/dev/null; }
f 110 "Movies/Vacation Highlights.mp4"; f 70 "Movies/Birthday Party.mov"; f 30 "Movies/Screen Recording.mov"
for i in $(seq 1 12); do f 4 "Photos/Summer Trip/IMG_$(printf %04d $i).jpg"; done
for i in $(seq 1 16); do f 3 "Photos/Family/IMG_$(printf %04d $((i+100))).jpg"; done
for i in 1 2 3 4 5 6; do f 15 "Photos/RAW/DSC_$(printf %04d $i).dng"; done
for i in $(seq 1 10); do f 8 "Music/Albums/Track $i.m4a"; done
for i in 1 2 3 4; do f 30 "Music/Podcasts/Episode $i.mp3"; done
f 12 "Documents/Taxes/2025 Return.pdf"; f 8 "Documents/Reports/Q3 Report.pdf"; f 3 "Documents/Reports/Budget.xlsx"
f 1 "Documents/Notes.txt"; f 45 "Documents/Design/App Mockups.sketch"; f 6 "Documents/Contract.pdf"
f 90 "Developer/Projects/webapp/build.tar.gz"; for i in $(seq 1 20); do f 1 "Developer/Projects/webapp/src/module$i.js"; done
f 60 "Developer/Projects/tools/main.swift.bin"
f 180 "Archives/Backup 2025.zip"; f 110 "Archives/Old Installer.dmg"
f 40 "Applications/Sketchbook.app/Contents/MacOS/Sketchbook"; f 12 "Applications/Sketchbook.app/Contents/Resources/assets.car"
f 85 "Downloads/Installer.pkg"; f 6 "Downloads/Statement.pdf"
for i in 1 2 3 4 5; do f 20 "Caches/Browser/cache-$i.db"; done
du -sh "$dest" | tail -1
