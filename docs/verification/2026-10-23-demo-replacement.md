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

## Follow-up 40027695341: shipping compilation failed

[Run 40027695341](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/40027695341) tested `b1ce2312d0e4cfe9723a86453d41b9bfe37157b7` (the same repair plus four Markdown files). It failed shipping Swift compilation: `SpacelyzerApp.swift:1368:28: error: cannot find 'FooterAXEvidence' in scope`. The new observer call sat outside SPZ_CI_TESTS while the observer declaration was CI-only. Extracted-function tests and independent review missed this conditional-context defect.

The universal engine and helper typecheck passed. Test-app build, demo, v1 capture and ordering were skipped: no new UI, ordering or screenshot acceptance exists. The demo diagnostic artifact and full logs were retained; the ordering upload had no results to upload and failed. The strict final gate failed. No automatic retry follows.

The offline follow-up guards the observer call with its actual CI-only condition; shipping emits unknown rather than importing the test observer or substituting intent. An executable Swift5/6 compiler control now preserves the real stateLine body and the observer's actual enclosing source conditions, with declared AppKit/observer-body stubs. The original source fails shipping with the exact Mac missing-symbol error while its CI form compiles; the repair typechecks in both configurations. This check is part of required Linux preflight, not a macOS SDK build. Native hosted accessibility and capture validation remain open.

Required preflight also generates a nominal-type availability model from the actual Swift source declarations, references and conditional directives, compiling shipping, CI and optional-perf/shots configurations. The old missing-observer boundary and an independently named new leak must fail; the repaired model must pass. Unsupported directives/malformed nesting fail the check. This conservative model lists ambiguous nested names it does not cover and excludes string-interpolation-only references. It does not compile API bodies or verify member/actor/native-SDK semantics. The actual stateLine body has the separate two-mode stub typecheck described above. None of these controls is a promise that all future compiler errors are preventable on Linux.

## Replacement 40042043674: compilation and checks passed, captures incomplete

[Run 40042043674](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/40042043674) tested `7d406a7322fe302591464df8b31f7d05f53ed860`, tree `802c3e2056ba631602dfbaa620146b4d0c728ee2`. Shipping Swift, isolated test Swift, universal engine and helper builds/typechecks passed. Ordering passed all 166 required checks exactly once; UI logs contain 178 PASS and zero FAIL. All 81 demo images exist and both artifacts uploaded. The whole run still failed, correctly: `asserts=failure v1cap=failure`.

Step 78 still records unknown identity although pixels show the intended Not scanned sheet. The native observer reports its exported AX walk unavailable, with 18 readable entries, 28 discovered nodes, six rejected branches and no truncation. Its existing unavailable message conflates owner matching and AXSheets lookup; the saved evidence does not establish which lookup failed. No specific AXSheets cause is claimed.

Five v1 captures were independently pixel-validated, including the now-clean trash-done state after observed result dismissal. History is missing. The actual step log says `not found: Removal history`; the overflow fallback then returned successfully, but the journal-content postcondition did not appear. The later snapshot contains the background window and overflow control, with no history popover. Successful AXPress is not proof that a panel opened. The mechanism failure remains unresolved; neither direct-press success nor a particular overflow bug is established by this record.

The follow-up diagnostics distinguish window read errors/types, owner candidate titles/errors, attached-pair freshness, owner match count, and AXSheets error/type/count. History snapshots bracket direct opening and overflow fallback; menu diagnostics record actual opener/item roles/text and action errors. These diagnostics do not change acceptance or repair either remaining capture failure. No additional run is authorized by them.
