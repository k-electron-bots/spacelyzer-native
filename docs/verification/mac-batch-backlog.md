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
