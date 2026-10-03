# Verification status

Status snapshot: October 3, 2026. Product focus boundary baseline `e2cd228`; latest checkpoint source `6c3bc6d`. This is a development app, **not release-ready**. Run114 compiled with 83 PASS / 1 FAIL of 84 and 42 captured states. The sole failure is native footer full-label retrieval; the tested window/mixed native-view discovery returned two objects without the full label. This does not prove external AX absence. Two actual mounted treemap resize checks passed, with pixels41/42 inspected: the held old520x300 publication was rejected after a newer680x360 layout, preserving exact published identity and Rust center-hit correspondence. Independent review accepted this bounded resize result. Run111's compact footer and run110's named focus evidence remain accepted; all historical failures remain recorded. No whole-keyboard, native-graph, external AX, real-hardware, full E2 or release claim follows.

## What evidence supports
| Area | Accepted scope | Limits |
|---|---|---|
| Engine | Linux/macOS engine jobs through run106; 32 tests in the recent checkpoints | Not exhaustive filesystem, permission, mount or APFS coverage |
| E1 outline and filters | Scoped acceptance across runs96/97, including deep-row/count and actual choice-submenu images | Not a whole-app accessibility or real-Mac approval |
| Async publication | Six specific UUID-barrier/cache/scan interleavings accepted; run113 actual mounted resize publication and pixels inspected, independently accepted within this bounded resize scope | One resize case only; Rust hit, not gesture dispatch, tree/filter/unmount or universal race guarantee |
| Count readability and layout | Inspected light/dark/injected contrast states, active reload after real alternate-window restoration, measured 960x600 root | Not actual OS notifications, offscreen cell reuse or formal contrast compliance |
| Zero-byte handling | Count/rect data, mocked removal-policy behavior, and inspected zero-area/no-match messages | Mocked policy tests do not prove real filesystem behavior |
| Trash round trip | Disposable real-CI remove + undo narrowly passed through107 | Not real-hardware, failure/undo or permission coverage |
| Footer | Run110 full variant and run111 natural compact variant fit simultaneous-warning fixtures; 37/38 semantics retained | Separate700pt CI surface only; warnings simulated, not permission/cancel accounting; actual help/external AX unverified; run112/113/114 strict native full-label retrieval failed |
| Keyboard focus | Run110 injected named boundaries and exact semantic extension-control navigation accepted; 80 PASS / 0 FAIL of 80 overall | Eleven helper controls passed within native-API/defensive-simulation scope; hidden/not-current predicates overlap. Old graph, modified-key/native-fallback and whole-keyboard behavior unproven |

## Named boundaries accepted; broader navigation and helper gaps remain
The product now uses an explicit known-control focus boundary instead of relying on native key-view graph traversal across hosts. Run107 expects 80 named checks and 39 states, adding actual reverse Tab plus 11 isolated helper/defensive API controls. Run109 exercised the faithful native reverse command and exact source acquisition. Run110 passed revised semantic downstream, post-hide preservation and actual refusal-callback/restoration contracts. Its expected extension control was unique and matched the actual editor delegate even though the native next-key-view pointer was nil. Helpers are not real modified-shortcut or native-fallback execution proof. False-with-changed-responder cases are simulations of defensive behavior, not a claim about normal AppKit behavior. The old key-graph contract remains unexercised/unfixed.

## Ungated performance measurements
Run111 sampled cold-click latency was 260.9 ms/stall252.8 ms, later click42.3 ms; 40-arrow p50/p95/max18.6/187.4/787.6 ms with stall789.6 ms, typing/filter-arrow stall162.1 ms, hover0.6 ms. This mixed shared-runner result is not an overall performance win. Buffered stages put about202 ms before table mouseDown and about2.65 ms inside it, but the raw8s sample lacks a wall/uptime overlap bridge and per-stack chronology. No frame or product cause is established.

Run110 measured a 2,096.7 ms first-click post-to-selection delay and a 2,093.2 ms main-thread stall, versus a 37.6 ms later click. Typing/filter arrows reached a 316.2 ms stall; 40-arrow latency was p50 35.7 / p95 74.6 / max 117.3 ms. Hover was 0.7 ms. These shared-runner measurements are outside the 80 green assertions. They do not prove a regression or a performance pass, and the first-click cause is unresolved.

## Remaining gates
Real-Mac use, VoiceOver/AX tree, actual IME, real OS accessibility notification/motion behavior, older-supported-OS behavior, broader window/multivolume behavior, permission/cancel accounting, broader real-hardware Trash/failure/undo behavior, leak/soak measurements and broader forced treemap interleavings remain open. Manual marked-text reset checks do not establish actual IME behavior or the old equal-while-marked premise.

[Run107](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37086620447), [run108](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37088229962) and [run109](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37089357517) are artifacts-only failures, not releases. Earlier failures and source/fixture decisions are in the [checkpoint ledger](checkpoints.md). [Roadmap](../ROADMAP.md) lists remaining product priorities.

[Content migration map](content-map.md) records where the useful former overview, technical, safety and checkpoint material now lives.

[Run110](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37092313793) is a bounded verification checkpoint, not a release. Actual modified shortcuts/native fallback, actual IME, VoiceOver/OS AX and full E2 gates remain open.

[Run111](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37094174463) adds bounded compact presentation and causal diagnostics, not performance or release acceptance. Actual footer help/AX, sample-stage overlap and FDA-copy pixels remain unverified.

## Latest failed checkpoints and bounded progress
[Run112](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37096739621): 81 PASS / 1 FAIL of82,40states. NSHostingView-root full-label retrieval failed. The paired clock/PID showed the raw sampler header283.47ms after input trace began, after the115.5ms selection wait, so startup acknowledgement did not prove cold-click coverage.

[Run113](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37098640048): 83 PASS / 1 FAIL of84,42states. Native mixed AX/view discovery still failed the full-label check. Mounted resize evidence and pixels41/42 passed within the narrow scope above. The explicit1s profiler-start settling arm has altered idle conditions and no cold comparability. MatchingPID/rawheader precedes trace by893.619ms, with subprocess end separately recorded; this is temporal alignment, not per-stack chronology or a performance pass. See the [ledger](checkpoints.md) and [performance notes](../development/performance.md).

[Run114](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37101601436): 83 PASS / 1 FAIL of84,42states. The explicit passive-summary accessibility combine modifier compiled, but strict native full-label retrieval still returned two objects without that label. Pixels39/40 full/compact warnings stayed readable;41/42 resize publication/hit evidence and pixels remained stable. No external accessibility absence, VoiceOver, tooltip or overall performance claim follows.
