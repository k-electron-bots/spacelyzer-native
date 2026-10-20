# Pending consolidated Mac validation

Source review and Linux checks do not close these gates. No new run, tag, release or spending is authorized by this checklist.

## Current baseline

- Last reviewed candidate before this docs batch: `dc764d5f5445f206faa187d51ab8e8e9060a8d34` (engine tests for rescan memory, cancelled scans and removal semantics are the newest changes).
- Last packaging attempt at `3f138cbc` failed in Finder AppleScript parsing. The sidebar-property removal at `5882c1a9` has not completed a packaging run.
- Docs batch 2a is a separate draft and waits for real captures. Do not replace missing images with mock screenshots.

## Evidence to collect

| Area | Run and inspect | Limit that stays open |
|---|---|---|
| Engine | Default and failpoints suites on APFS; save exit codes, per-binary totals and platform-skip names separately | Linux passes are not APFS evidence |
| App | Build normal and test Swift products on the exact candidate; save toolchain versions and source SHA | Source checks are not compilation |
| Ordering driver | Run required-manifest check, capture every named result exactly once, retain assertion text and real UI images | Injected fixtures do not prove real-system input or VoiceOver |
| Cleanup | Disposable fixture: inspect, full-path confirmation, one-item/batch Trash, undo and history; failure, protected-path and identity-change cases | No user-file cleanup; no release-readiness inference |
| CSV export | Compile; run the three declared export checks in [review-popover-future-mac-checks.md](../development/review-popover-future-mac-checks.md); save a real list and open it with UTF-8 import | Source only today; never compiled, never opened in Excel |
| Stability | Repeated rescans, tree swaps/cancel and long-session measurements, with memory samples and stall logs | Do not infer a plateau from one scan. Linux engine-only checks exist (`engine/tests/rescan_memory.rs`, `partial_scan.rs`, `removal_semantics.rs`); they say nothing about Swift, APFS or a long session |
| Icon | Inspect installed app icon at small sizes and in Finder | Asset pixels alone do not prove macOS rendering |
| Installer | Create signed development DMG; mount; inspect Finder background/layout, app and Applications positions, 1x/2x appearance; verify detach | Self-signing is not Developer ID or notarization |
| Documentation | The pinned candidate has 4 existing image slots in `docs/guide/tour.md`, all with PNGs present. The unmerged `ux-docs-2a` draft (`797cdcd`) adds 6 pending image slots and marks the 4 existing tour.md slots for refresh from real captures; collect real captures for that draft and check captions against the final UI | Draft text is not a screenshot or supported-OS verification |

## Runner limits

`scripts/local-mac-check.sh` is a focused ordering runner, not the whole table above. Its default reviewed-tree pin and measured Rust-count expectations belong to an older tree. Supply a separately reviewed `--expect-tree` value for a newer tree; never call an observed count a pinned expectation before a real Mac log exists. Its own NOT-COVERED summary remains in force.

The setup failure-propagation repair is tested with stub commands on Linux only. Successful setup, Swift compilation, real windows and screenshots still need a Mac. Setup explicitly downloads toolchains/dependencies; validation is offline. Do not launch the script on someone's Mac without arranging an uninterrupted session, since its UI checks take focus.

`ci.yml` has a manual `consolidated` input (default off; the ordinary workflow is unchanged). When set, one extra launch runs the ordering driver (157 required checks, each exactly once, from `scripts/check-ordering-manifest.py`) and the informational macOS scan benchmark is skipped. Nothing here is a Mac result until a real run log exists. Not run: the poison-variant launch, repeated rescans, long sessions, cancel latency and 1M-entry publication timing.

`ci.yml` also has an exclusive manual `perf` input (default off; not part of the consolidated run). It builds the test-only app and runs only `SPZ_CHECKS=perf` (`Sources/Spacelyzer/PerfDriver.swift`, compiled only with `SPZ_CI_TESTS`): three cancel runs at a measured item count and one full scan, timestamping cancel call return, engine return, scanning flag false, tree published, outline rows/version, derived version and layout version. It states no threshold or budget. The scanned folder (`perf_root`, default `/Applications`) and its item count are measured and reported, not assumed. A missing milestone makes the run INCOMPLETE and fails the build instead of printing a duration. Shared-runner numbers are ballpark only; the real-machine measurement on the private build remains open.

`ci.yml` has an experimental manual `docs_2x` input (default off). After the unchanged real 1x docs captures it runs `scripts/docs-capture-2x.sh` against the TEST-ONLY app, which re-renders the window content view at 2 pixels per point (`Sources/Spacelyzer/ShotServer.swift`, compiled only with `SPZ_CI_TESTS`) into `dist/screenshot-docs-2x-render-*.png`, each with a `.txt` saying how it was made. These are render-derived images, not native Retina display captures, and they exclude the title bar and shadow. The real non-test app path is unchanged and remains the authentic 1x source. No 2x image may be used in docs before its pixels are inspected against the 1x capture of the same state (layers can be missing).

Run readiness (batch 31). Order in the macOS job: core steps, test-only build, demo launch, UI assertions, then the core artifact upload; the optional steps (docs captures, ordering driver, docs_2x, perf) run after that and each uploads its own artifact (`-docs`, `-ordering`, `-docs-2x`, `-perf`) with `always()`, so a later step that hangs or runs out of time cannot take earlier evidence with it. In consolidated mode the Rust tests, bulk-vs-portable check and DMG packaging become continue-on-error so later evidence is still produced; the final step still fails the build if any of them, the ordering driver, or the UI assertions did not succeed. The perf driver and the 2x shot server compile only behind their own flags (`SPZ_CI_PERF`, `SPZ_CI_SHOTS`), set only when `perf`, `perf_in_run` or `docs_2x` is requested; the default and consolidated test builds contain neither. If the optional code fails to compile, the core test app is rebuilt without it and the build is failed visibly at the end. `perf_in_run` runs the perf driver after the other steps without skipping anything. Per-step timeouts: docs 8, ordering 7, docs_2x 6, perf 8 minutes. None of this is a Mac result until a real run log exists.

Audit additions (batch 31): the optional docs steps now follow the demo, which ran the same bundle id, so a reset step prints and then clears that bundle's UserDefaults and saved window state before the docs captures (the defaults it printed are kept in the step log as evidence of what the demo left). A final always() step stops any app left running or a mounted install image after a step timeout. A skipped required step counts as not succeeded in the final gate.

Reset step detail (batch 31): it stops every Spacelyzer process first (SIGTERM, bounded wait, SIGKILL, then fails if any survives) before deleting the defaults domain, removes the preferences plist and saved window state, restarts cfprefsd, and then proves the result: the defaults domain must report "does not exist", and the plist and saved state must be absent. Anything else, including an unreadable result, fails the step. Its evidence is written to `dist/docs-reset-evidence.txt` and uploaded with the docs artifact. Both docs capture steps run only if the reset step succeeded, and the final gate fails the build if it did not, so docs captures are never accepted from an unreset state.
