# Roadmap

Priorities, in order: safety, real and perceived performance, pixel polish, then new features.
"Verified" means checked by the CI demo run (real events posted to the app window on a shared GitHub Mac, screenshots
read by a person). Nothing here has been verified on a personal Mac yet.

## Done and verified on CI
- Rust engine: parallel scan, flat tree, hard-link and firmlink handling, filter, outline projection, treemap layout and hit-testing.
- Windowed outline (no row cap), keyboard navigation, one filter for every view, "No matches" states.
- Selecting a file hidden in collapsed folders expands its ancestors (CI check 19). Extension and maximum-size filters in the UI (CI checks 20-21); modified-date window checked as narrow <= wide (check 22; it does not verify individual mtimes).
- Selection safety: Move to Trash is unavailable when the selection is hidden by the filter or a filter result is pending.

## Underway
1. Verify real Trash round trip on a disposable fixture (in CI), and main-thread stall measurements for hover, typing and expand-all.
2. Largest and Kinds lists moved off the main thread and cached (committed, awaiting CI proof).

## How work is organised
Features are grouped in epics. Tasks inside an epic are thin commits in dependency order, one concern each. CI, tags and releases run per epic (push tag `epic-<n>-<name>`), not per task, to save free-tier quota. Each epic ends with CI assertions plus inspected screenshots before it is called done.

## Epics
1. Outline and filters (E1): reveal ancestors (done, CI 19), extension/size/date filters (done, CI 20-22), item counts (shown in rows wide enough, not visible at the 1024x768 CI window; unverified visually), sort options (Rust sort modes tested; UI check 23 PASS in epic-1 run 37022036702). E1 first run: epic-1-outline-filters (independent review found: zero-byte matches hidden, empty-folder counts missing, screenshots covered by a modal). Fixes and unobstructed control and menu evidence: epic-1b-outline-filters.
2. Glass and accessibility (E2): selection bar and buttons, filter field, Reduce Transparency/Motion, minimum window size, VoiceOver labels and tree check.
3. Volume and space accounting (E3): used/free/purgeable, snapshots, unaccounted space.
4. Inspect and remove (E4): details, Quick Look, then batch removal with history (depends on details).
5. Scan control (E5): persistent exclusions, unreadable-location list, Full Disk Access detection.
6. Duplicates (E6): Rust duplicate finder, then UI (depends on E4 removal).
7. Polish (E7): app icon, decimal/binary units, long-session soak and leak check, cold first-click investigation.

## Not verified
Real-Mac behaviour, other window sizes, multiple volumes, APFS clones, purgeable space, VoiceOver.

## Cross-cutting: stability and memory (required before any release is called ready)

Status: v0.1.48 had a crash when a second folder was scanned after a large tree (stale node ids). Fixed in source; regression not yet confirmed by CI.

- [ ] Rescan and tree-swap regression in CI (large then small, cancel mid-scan).
- [ ] Memory plateau across repeated rescans, with measured resident size.
- [ ] Long-session soak with sampled memory.
- [ ] Cancellation and failure recovery checks.
- [ ] FFI bounds checks for node ids; leak check for Rust allocations.
- [ ] CI fails if the app is not running at the end of the demo.
