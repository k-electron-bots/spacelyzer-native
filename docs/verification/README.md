# Verification status

Status as of October 25, 2026. **Not release-ready.** No release, DMG distribution or notarization has been done. Every result below is from a named CI run; none is a guarantee.

Older snapshot: [HISTORY-2026-10-06.md](HISTORY-2026-10-06.md). Ledger: [checkpoints.md](checkpoints.md). Open Mac items: [mac-batch-backlog.md](mac-batch-backlog.md).

Newest completed native run: [40098663789](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/40098663789)
on `ca736b6` (October 24). It passed 178 UI assertions and 166 ordering checks,
recovered the external-sheet capture that failed in 40050466225, and produced all
six original v1 captures. The whole run still failed: the only red stage was the
wide-history resize, where the app window measured 992x665 on a 1024x768 runner
(visible area 1024x677) instead of 1280 wide. Run-level evidence is kept separate
from 40050466225 below.

Landed since, not yet run on a Mac: `7ddc832` (main) replaces that wide-history
step with an in-app resize responder, a window-id capture and width checks tied to
the requested 1280. It was tested offline on Linux with stubs only. Three Mac runs
on `7ddc832` (40105344288, 40108846372, 40130926991) were dispatched and are still
queued with no job started, so the new path has no native evidence. Still **not
release-ready**.

Previous: [combined verification and screenshot evidence](2026-10-23-combined-verification.md).
Run 40050466225 on `9db328b5` passed native shipping/test/helper compilation,
166 ordering and 178 UI assertions. All six original v1 captures were inspected,
including newly visible compact Removal History. The whole run still failed:
external Not scanned observation returned AXWindows error -25204, and wide
history resize dimensions were not observed. Five valid cleanup images now
illustrate the README/tour/safety guide; older overview/Kinds/review/installer
images remain dated earlier evidence. No new DMG or release.

## What a Mac has executed

| Area | Run | Result | Limit |
|---|---|---|---|
| Latest completed native run | [40098663789](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/40098663789) on `ca736b6` | 178 UI assertions and 166 ordering checks passed; external-sheet capture recovered; six original v1 shots OK | Whole run failed: wide-history resize measured 992x665 on a 1024x768 runner (visible 1024x677), not 1280 wide. Not release-ready |
| Earlier native check execution | [40050466225](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/40050466225) | 178 UI assertions and 166 required ordering checks passed; shipping/test/helper builds passed; compact history visible | Whole run failed external observed identity and wide-history capture; not release-ready |
| Functional UI and ordering | [39683697776](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/39683697776) | 178/178 UI assertions, 159/159 ordering checks | Fixture data on a shared CI Mac |
| Real Trash, undo, identity refusal, name collision, failure recovery | [39843869589](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/39843869589) | 178 PASS / 0 FAIL, including a real Trash move of only the selected fixture; keyboard-focus checks passed | The run failed at artifact upload and the gate, so it is not a clean pass. Demo screenshots 72-81 were stale or blank; that capture bug has a fix |
| Test-only build with the capture fix | [39858272561](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/39858272561) | Compiled on the Mac | Compile only. The 1M-item scale run in that job did not complete |
| Size accuracy against an independent oracle | [39871364562](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/39871364562) | Run failed on a harness path-alias bug (/var vs /private/var). A hash-bound recompare of the saved output showed 0 differences in 12 of 12 legs (1k, 10k, 100k items; with and without hard links; default and portable) | Recompare is post-hoc, not a clean run. Fixture-scoped. See [accuracy evidence](../development/ACCURACY-EVIDENCE.md) |

## Open

- Wide-history capture remains open. Run 40098663789 measured the clamp; the `7ddc832` correction is Linux/stub-tested only. Its native sizing, window-id capture and popover capture are unverified until a Mac run starts and its images are inspected. The height rule (1280 x min(800, visible height), within 2 px) is a test-side policy.
- Capture acceptance remains open: run 40050466225 has six inspected original v1 captures, but the external sheet observer failed AXWindows (-25204), and the added wide-history resize was not observed. Native `sheetId=unknown` remains separate from the named observed-sheet-v1 criterion, which also failed. Compact history opening is now demonstrated; wide positioning is not. See dated evidence above.
- The Linux-only 4 KB ancestor anomaly (NOLINKS, seed 100008, 100k) remains OPEN: not reproduced with its recorded parameters on October 23 (retained artifact shows 0 per-node diffs); original raw lost, observation unexplained and unretired. Separately, run-to-run hard-link attribution flips on the parallel backend were found and reproduced (order-dependence; a deterministic-attribution change is a pending owner decision). See checkpoints.md.
- Three CSV formatting/export-flow/model-wiring checks passed on the CI Mac with injected panel/write seams. Real save-panel/file/import behavior and actual IME input remain unverified. VoiceOver speech is untested and is not a v1 gate.
- Hard-link sizes are counted once for the whole scan, so a per-folder figure can depend on which link is reached first. This is by design.
- Several name-handling cases are not exercised on macOS because APFS refuses those names. They are limits, not passes.

## Screenshots

Only window-only captures from named runs are published, per the [documentation policy](../documentation-policy.md). The demo run's full-screen captures include the menu bar and Dock and are evidence, not documentation images.
