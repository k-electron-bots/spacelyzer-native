# Known limitations

Spacelyzer 0.9.x is early software. These are the things to know before you rely on it.

## Installation
- The app is self-signed and not notarized by Apple. macOS blocks the first open until you choose **Open Anyway** in **System Settings > Privacy & Security** ([steps](install.md#first-launch)).

## What the numbers cover
- Sizes are allocated bytes. Hard-linked files count once.
- Locations the app cannot read are skipped, and their bytes are in no total. Full Disk Access widens coverage but does not guarantee every protected path.
- Files whose names are not valid UTF-8 are listed as unreadable, and their sizes are not in any total.
- The list of skipped locations may not include every unreadable entry.
- A canceled or partial scan covers less than a full one.
- Totals are not a full volume-accounting model. Purgeable space, APFS snapshots and clone (copy-on-write) accounting are not modeled, so the total can differ from what Finder reports.

## Removal
- Removal always goes to the Trash after a confirmation that shows the full path, and can be undone from Removal History.
- Protected paths, selections outside the current filter and selections still waiting on a filter result are refused.
- Allocated bytes in the duplicate review are not always recoverable space: sparse, compressed and some cloned copies free less than they show.

## Interface
- Typing in the filter field with an input method (for example Chinese, Japanese or Korean composition) has had limited testing.
- VoiceOver support is built in but has not been tested with speech output.
- Very large scans (around a million items) have had limited testing. Expect them to take longer and use more memory.
- CSV export writes UTF-8 without a byte order mark. Excel can misread non-ASCII names when it opens the file directly; use its import option with UTF-8 selected.

## Privacy
- The app has no networking code. Scanning, filtering and removal run locally.

Found something else? Open an issue on the [repository](https://github.com/k-electron-bots/spacelyzer-native/issues).
