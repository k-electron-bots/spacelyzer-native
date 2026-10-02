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
1. Outline and filters (E1): reveal ancestors (done, CI 19), extension/size/date filters (done, CI 20-22), item counts (shown in rows wide enough, not visible at the 1024x768 CI window; unverified visually), sort options (Rust sort modes tested; UI check 23 PASS in epic-1 run 37022036702). E1 first run: epic-1-outline-filters (independent review found: zero-byte matches hidden, empty-folder counts missing, screenshots covered by a modal). Epic-1b run 37025735089 (16e7f46): 26 of 28 assertions passed, the two NSMenu item-pick checks failed (menus fill on open); real typing in the ext field passed. Epic-1c run 37030720991 failed: only 26/28 checks reached; the menu driver did not complete. Diagnostic v0.1.89 is not signed off. Consolidated run37036910990 compiled and reached all30 checks: 29PASS, above400 fixture FAIL because width was651pt not401pt. Date/sort/reset effect checks PASS, but exact-step polling skipped later screenshots. Divider targeting and state-synchronous screenshot collection are repaired; new consolidated CI and independent signoff pending.
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

## Evaluated, not scheduled
- E8 Incremental rescan (persisted tree + FSEvents): see docs/EVAL-incremental-scan.md. Not implemented. Spotlight is not used for totals.

- Index-assisted early results and dua-cli progressive traversal: see [evaluation](EVAL-index-accelerant.md). Evaluation only, distinct from persisted-tree/FSEvents repeat-scan work.
