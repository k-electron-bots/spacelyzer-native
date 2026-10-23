# Verification status

Status as of October 22, 2026. **Not release-ready.** No release, DMG distribution or notarization has been done. Every result below is from a named CI run; none is a guarantee.

Older snapshot: [HISTORY-2026-10-06.md](HISTORY-2026-10-06.md). Ledger: [checkpoints.md](checkpoints.md). Open Mac items: [mac-batch-backlog.md](mac-batch-backlog.md).

## What a Mac has executed

| Area | Run | Result | Limit |
|---|---|---|---|
| Functional UI and ordering | [39683697776](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/39683697776) | 178/178 UI assertions, 159/159 ordering checks | Fixture data on a shared CI Mac |
| Real Trash, undo, identity refusal, name collision, failure recovery | [39843869589](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/39843869589) | 178 PASS / 0 FAIL, including a real Trash move of only the selected fixture; keyboard-focus checks passed | The run failed at artifact upload and the gate, so it is not a clean pass. Demo screenshots 72-81 were stale or blank; that capture bug has a fix |
| Test-only build with the capture fix | [39858272561](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/39858272561) | Compiled on the Mac | Compile only. The 1M-item scale run in that job did not complete |
| Size accuracy against an independent oracle | [39871364562](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/39871364562) | Run failed on a harness path-alias bug (/var vs /private/var). A hash-bound recompare of the saved output showed 0 differences in 12 of 12 legs (1k, 10k, 100k items; with and without hard links; default and portable) | Recompare is post-hoc, not a clean run. Fixture-scoped. See [accuracy evidence](../development/ACCURACY-EVIDENCE.md) |

## Open

- Pixel review of the demo captures 72-81 after the fix: needs a new Mac run.
- A Linux-only size anomaly (a 4 KB difference at an ancestor directory) is open. No raw log was retained.
- CSV export and actual IME input are not verified on a Mac. VoiceOver speech is untested and is not a v1 gate.
- Hard-link sizes are counted once for the whole scan, so a per-folder figure can depend on which link is reached first. This is by design.
- Several name-handling cases are not exercised on macOS because APFS refuses those names. They are limits, not passes.

## Screenshots

Only window-only captures from named runs are published, per the [documentation policy](../documentation-policy.md). The demo run's full-screen captures include the menu bar and Dock and are evidence, not documentation images.
