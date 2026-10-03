# Roadmap

Priorities: safety, real and perceived performance, pixel polish, then features. This page describes future work. [Verification status](verification/README.md) describes accepted evidence; [checkpoint history](verification/checkpoints.md) preserves failed and superseded attempts.

## Current priorities
1. Extend the bounded injected focus evidence to actual modified-key/fallback behavior and real-system input. The named boundaries and semantic extension route passed run110, not whole-keyboard or native-graph repair.
2. Ground the cold first-click and typing stalls, then complete E2 accessibility and real-system validation. Injected preferences or labels are not VoiceOver proof.
3. Prove removal, partial scans, stability and memory behavior on disposable fixtures before a release is called ready.

## Product epics
| Epic | Scope and dependencies | Status |
|---|---|---|
| E1 Outline and filters | Ancestor reveal, extension/size/date filters, sort, deep item counts, zero-byte matches | Scoped CI/pixel acceptance across checkpoints; see verification limits |
| E2 Glass and accessibility | Selection/action surface, native filter editor, focus, Reduce Transparency/Motion, minimum layout, VoiceOver | Underway; full signoff open |
| E3 Volume accounting | Used/free/purgeable space, snapshots, unaccounted space | Planned |
| E4 Inspect and remove | Item details and Quick Look, then batch removal/history | Planned; batch work depends on details and safety |
| E5 Scan control | Persistent exclusions, reviewable unreadable list, Full Disk Access detection | Planned |
| E6 Duplicates | Rust duplicate finding and review/removal UI | Planned; depends on E4 |
| E7 Polish and endurance | App icon, decimal/binary units, cold first-click investigation, long-session soak/leaks | Planned; stability is cross-cutting |

## Release gates across epics
- Broader Trash failure/undo and real-hardware behavior beyond the narrow disposable CI remove/undo pass.
- Rescan/tree-swap/cancel recovery, including old work released after a newer result.
- Memory plateau across repeated rescans, long-session sampling and Rust/FFI leak/bounds checks.
- Main-thread stall measurements for hover, typing and expand-all.
- App alive at the end of the demo, with canonical named assertion results and inspected images.
- Real hardware, multiple volumes, permission-denied/mount changes, APFS clones, actual accessibility and input-method behavior.

Do not weaken a failed or missing check into a source-only success. Historical assertions about stale-node fixes, caches or planned checks are in the ledger with their original evidence scope.

## Evaluated, not implemented
[Persisted-tree/FSEvents incremental rescan](EVAL-incremental-scan.md) and [index-assisted early results](EVAL-index-accelerant.md) are separate proposals. Spotlight does not own scan totals. Neither proposal is a shipped feature.

## Delivery cadence
Thin dependency-ordered commits inside an epic. Coordinate substantive checkpoints; capture actual UI states and review pixels before accepting a visual change. Diagnostic DMGs and artifacts do not establish release readiness.
