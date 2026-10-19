# Pending consolidated Mac validation

Source review and Linux checks do not close these gates. No new run, tag, release or spending is authorized by this checklist.

## Current baseline

- Candidate after docs batch 2b: `7205e1262a21cc3b14471b91f54ffe6bbaa021ff`.
- Last packaging attempt at `3f138cbc` failed in Finder AppleScript parsing. The sidebar-property removal at `5882c1a9` has not completed a packaging run.
- Docs batch 2a is a separate draft and waits for real captures. Do not replace missing images with mock screenshots.

## Evidence to collect

| Area | Run and inspect | Limit that stays open |
|---|---|---|
| Engine | Default and failpoints suites on APFS; save exit codes, per-binary totals and platform-skip names separately | Linux passes are not APFS evidence |
| App | Build normal and test Swift products on the exact candidate; save toolchain versions and source SHA | Source checks are not compilation |
| Ordering driver | Run required-manifest check, capture every named result exactly once, retain assertion text and real UI images | Injected fixtures do not prove real-system input or VoiceOver |
| Cleanup | Disposable fixture: inspect, full-path confirmation, one-item/batch Trash, undo and history; failure, protected-path and identity-change cases | No user-file cleanup; no release-readiness inference |
| Stability | Repeated rescans, tree swaps/cancel and long-session measurements, with memory samples and stall logs | Do not infer a plateau from one scan |
| Icon | Inspect installed app icon at small sizes and in Finder | Asset pixels alone do not prove macOS rendering |
| Installer | Create signed development DMG; mount; inspect Finder background/layout, app and Applications positions, 1x/2x appearance; verify detach | Self-signing is not Developer ID or notarization |
| Documentation | The pinned candidate has 4 existing image slots in `docs/guide/tour.md`, all with PNGs present. The unmerged `ux-docs-2a` draft (`797cdcd`) adds 8 pending image slots; collect real captures for that draft and check captions against the final UI | Draft text is not a screenshot or supported-OS verification |

## Runner limits

`scripts/local-mac-check.sh` is a focused ordering runner, not the whole table above. Its default reviewed-tree pin and measured Rust-count expectations belong to an older tree. Supply a separately reviewed `--expect-tree` value for a newer tree; never call an observed count a pinned expectation before a real Mac log exists. Its own NOT-COVERED summary remains in force.

The setup failure-propagation repair is tested with stub commands on Linux only. Successful setup, Swift compilation, real windows and screenshots still need a Mac. Setup explicitly downloads toolchains/dependencies; validation is offline. Do not launch the script on someone's Mac without arranging an uninterrupted session, since its UI checks take focus.
