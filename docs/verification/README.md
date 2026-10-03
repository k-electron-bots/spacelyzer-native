# Verification status

Status snapshot: October 2, 2026. Boundary source baseline `e2cd228`; run107 results reported separately below. This is a development app, **not release-ready**. Run107 is the coordinated artifacts-only checkpoint for the explicit native focus boundary. Its 67 PASS / 13 FAIL of 80 results are scoped: forward Tab reaching the exact field/editor is independently accepted; two reverse checks and all 11 helper checks failed. Run108 at fixture source `72e178a` also returned 67 PASS / 13 FAIL of 80. Its posted Shift-Tab reached the exact field/editor but dispatched `insertTab:`, not `insertBacktab:`. The eleven helper checks were blocked before guard execution: the source table refused first-responder status and the actual responder was the fixture window, despite a true acquisition API result. Neither failure proves a product guard bug or clears the reverse handler. The fixture change is separate from product source `e2cd228` and establishes no new runtime acceptance.

## What evidence supports
| Area | Accepted scope | Limits |
|---|---|---|
| Engine | Linux/macOS engine jobs through run106; 32 tests in the recent checkpoints | Not exhaustive filesystem, permission, mount or APFS coverage |
| E1 outline and filters | Scoped acceptance across runs96/97, including deep-row/count and actual choice-submenu images | Not a whole-app accessibility or real-Mac approval |
| Async publication | Six specific UUID-barrier/cache/scan interleavings accepted | No forced treemap-race proof or universal race guarantee |
| Count readability and layout | Inspected light/dark/injected contrast states, active reload after real alternate-window restoration, measured 960x600 root | Not actual OS notifications, offscreen cell reuse or formal contrast compliance |
| Zero-byte handling | Count/rect data, mocked removal-policy behavior, and inspected zero-area/no-match messages | Mocked policy tests do not prove real filesystem behavior |
| Trash round trip | Disposable real-CI remove + undo narrowly passed through107 | Not real-hardware, failure/undo or permission coverage |
| Footer | Run106 full variant fits the simultaneous-warning fixture; 37/38 semantics retained | Compact variant unexercised; warnings simulated, not permission/cancel accounting |
| Keyboard focus | Run107 exact forward Tab to named field/editor independently accepted; 67 PASS / 13 FAIL of 80 overall | Run108 reverse2 failed; helper11 blocked by invalid source acquisition; old graph, modified-key/native-fallback and whole-keyboard behavior unproven |

## Forward boundary accepted; reverse and helper behavior pending
The product now uses an explicit known-control focus boundary instead of relying on native key-view graph traversal across hosts. Run107 expects 80 named checks and 39 states, adding actual reverse Tab plus 11 isolated helper/defensive API controls. Helpers are not real modified-shortcut or native-fallback execution proof. False-with-changed-responder cases are simulations of defensive behavior, not a claim about normal AppKit behavior. The old key-graph contract remains unexercised/unfixed.

## Remaining gates
Real-Mac use, VoiceOver/AX tree, actual IME, real OS accessibility notification/motion behavior, older-supported-OS behavior, broader window/multivolume behavior, permission/cancel accounting, broader real-hardware Trash/failure/undo behavior, leak/soak measurements and forced treemap interleavings remain open. Manual marked-text reset checks do not establish actual IME behavior or the old equal-while-marked premise.

[Run107](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37086620447) and [run108](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37088229962) are artifacts-only failures, not releases. Earlier failures and source/fixture decisions are in the [checkpoint ledger](checkpoints.md). [Roadmap](../ROADMAP.md) lists remaining product priorities.

[Content migration map](content-map.md) records where the useful former overview, technical, safety and checkpoint material now lives.
