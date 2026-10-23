# October 23: native checks passed, capture acceptance failed

[Run 40022177880](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/40022177880) tested source `d9d2b7544cc65f2827bc0d37de8fdf1bef5eb6bf`. The whole run **failed**. Passing checks below do not turn it into a clean validation or release-readiness result.

## Accepted execution evidence

- Universal shipping Rust engine, shipping Swift, helper typecheck/build and the isolated CI test app built on the CI Mac.
- Ordering result: `PASS 166 required checks, each exactly once`; 166 PASS, no FAIL. This includes the three CSV formatting/export-flow/model-wiring checks and the two deterministic parked scan-cancellation checks.
- UI assertion log: 178 PASS, no FAIL. The later strict capture-state gate failed independently.
- Both demo and ordering artifacts uploaded. This attempt did not fail at artifact upload.

CSV scope is the real model with injected panel/write seams. A real NSSavePanel, overwrite confirmation, file readback and Excel/Numbers import remain unverified. Cancellation checks reached the real engine/C ABI and partial-tree publication on a disposable fixture; their coarse completion bounds are not UI dispatch-latency measurements or 1M-item performance proof.

## Failed acceptance

All 81 demo PNGs existed, but strict fidelity rejected step 78: `sheet=true keyIsSheet=true alertModel=false sheetId=unknown sheetRows=1`. Pixel inspection showed the intended Not scanned sheet. The observer enumerated NSTextField views, which does not establish the text exported by hosted SwiftUI accessibility nodes. The gate stayed red rather than substituting presentation intent.

The v1 capture script reported five files of six, but only **four of six were valid intended captures**. The trash-done image still showed the Moved-to-Trash result alert; it was not a valid done state. Removal history was missing. The retained history snapshot still showed the result alert and a toolbar overflow control. File count is not state acceptance.

The final gate correctly reported `asserts=failure v1cap=failure`. Continue-on-error step conclusions must not be read as successful outcomes.

## Reviewed offline repair, not native validation

[Repair 48d7462](https://github.com/k-electron-bots/spacelyzer-native/commit/48d7462f8a5257bdbd5cf4f6ba1b76d5aaa5c134), tree `fa352805e9c036483057a13e940929c3d46e6a7d`, landed after independent review:

- Sheet identity uses the attached sheet's observed accessibility label/value. The exported-tree route requires a unique owning window and its unique AXSheets child. Unknown/truncated evidence still refuses identity.
- Capture presses the observed OK button once and requires a readable no-panel observation before **both** trash-done and history. Missing/unreadable evidence withholds both captures.
- History can use the Removed toolbar-overflow item, but still must show this fixture's journal entry.

Offline controls execute the extracted real classifier and no-panel Swift command body, plus the capture script against declared AX states. The original script fails the sticky-alert/overflow regression; the repair passes, including stuck-OK and unreadable-AX refusals. Helper preflight, workflow checks and shipping/Swift isolation controls pass on Linux. These are not a macOS SDK, native AX or pixel result.

Still required: real Mac compilation and hosted AXSheets observation, actual alert dismissal and toolbar-overflow behavior, all strict capture/ordering gates, and pixel review of the intended states. No additional run, release, DMG, scale or soak is authorized by this document.
