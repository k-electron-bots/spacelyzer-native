# Roadmap

Priorities: safety, real and perceived performance, pixel polish, then features. This page describes future work. [Verification status](verification/README.md) describes accepted evidence; [checkpoint history](verification/checkpoints.md) preserves failed and superseded attempts.

## Current priorities
1. Extend the bounded injected focus evidence to actual modified-key/fallback behavior and real-system input. The named boundaries and semantic extension route passed run110, not whole-keyboard or native-graph repair.
2. Ground the cold first-click and typing stalls, compare equivalent release builds and audit UI/FFI/rendering costs, then complete real-system validation. VoiceOver speech verification is owner-descoped for v1 (2026-10-22); the accessibility features remain built, unverified by actual VoiceOver.
3. Prove removal, partial scans, stability and memory behavior on disposable fixtures before a release is called ready.

## First usable release priority
Safe big-file cleanup comes first, ahead of hidden macOS space/snapshot/accounting explanations. Build useful inspect/preview and reviewed Trash workflows on the existing Largest/outline surfaces. Responsiveness, current-file identity validation, permissions, protected paths, failure and undo gates remain; this direction does not authorize automatic deletion or establish release readiness. The cleanup workflow is now built on the development tree: one-item and batch removal with a preview, full path, undo and removal history. Mac verification of that workflow is still open, so nothing here is a release-readiness claim. Hidden-space accounting stays planned after this first usable workflow.

## Near-term steps, in dependency order
Each step names its gate. None is a release-readiness claim, and none authorizes a Mac CI run, a release or spend; the Mac verification gate is owned by the project owner.
1. **Mac verification of the current stack (blocks everything Swift).** Run 39602481035 (2026-10-21, one approved consolidated run) compiled the full app on Mac, passed 178/178 UI and 159/159 ordering checks once - including all seven previously failing checks - and 169 exercised Rust test passes with 5 documented platform skips (raw cargo count 174; cargo counts the skips as passed). Passed once is not proven stable. Run 39683697776 (2026-10-21, consolidated) then evaluated the bulk backend-vs-portable comparison on real Mac trees (binding cold-pair agreement on the fixture, /Applications and /usr/lib; informational home-library agreement) and captured the DMG install window with the merged label-contrast plates (pixel-reviewed). Still unknown on Mac: actual VoiceOver speech (in-process AX evidence only; no supported automated speech capture). Older evidence: one hosted macOS compile of the `f5c50283` tree built the universal Rust engine and Swift with 0 errors and 20 warnings. Run 39683697776 added Mac results for the Rust suite (283 passed, 0 failed, 8 documented platform skips) and the failpoints (9/9).
2. **Mac verification of the built Swift consumers.** The engine's previously headless capabilities now have Swift UI: the Not scanned list, the exclusions editor with unobserved-exclusion reporting, the volume header, the duplicates review, and item inspect. Their named check suites passed on Mac in runs 39602481035/39683697776 (178/178 UI, 159/159 ordering). Per-surface pixel capture is partially reviewed (review popover and DMG window verified); remaining captures follow the docs batch.
3. **Mac verification of the cleanup workflow (E4).** Inspect, preview, full path, Trash, undo, batch removal and removal history are built per the owner's October 3 priority, and the safety gates are implemented in current code: the identity revalidation (one engine lstat, `spz_tree_check_identity`) and the Trash move run off the main actor, one removal at a time, with mutation/scan/undo exclusion, protected-path, filter-coherence and poison gates (`AppModel.confirmRemoval`, the batch path and `runRestore`). The named check suites passed on Mac in runs 39602481035/39683697776. Open gates: every check mocks the Trash seam, so no REAL Trash move has executed anywhere yet; failure/undo/protected-path behavior on real hardware and real volumes is unverified.
4. **Real-system input evidence (E2).** Real-system input, not injected preferences. VoiceOver speech verification is owner-descoped for v1 (2026-10-22): the accessibility features stay in the product, actual VoiceOver speech remains unverified and optional, not a v1 gate.
5. **Stability evidence (E7).** Memory plateau over repeated rescans, long-session soak, main-thread stall measurements for hover, typing and expand-all, on release builds. No speed or reclaimable-space claim exists until then. Today only an engine-level, Linux, debug-build check exists (`engine/tests/rescan_memory.rs`: resident growth across repeated rescans through the C ABI, with a deliberate-leak control). It says nothing about the Swift side, macOS or a long session.

## Long-range hypotheses (not planned work, no evidence yet)
- Hidden-space accounting: purgeable space, APFS snapshots, container sharing and clone accounting, shown as separate labeled numbers, never merged into one total. Needs Mac-only APIs; unresearched on real volumes.
- Persisted-tree and FSEvents incremental rescan, and index-assisted early results (see the two evaluation pages). Each must prove it cannot show a stale total as current.
- Scheduled or background re-scan reminders, and a "what changed since last scan" view. Both need the persisted-tree work first.
- Cloud/placeholder file awareness (files not materialized locally), and external or network volumes. Need dataless-file and volume-change semantics checked on real systems.
- Distribution (signing, notarization, update channel): deferred by the owner (2026-10-22) - not a current blocker, not started, no Apple-account spend. Development DMGs stay self-signed and not notarized, with no production-trust claim.

## Product epics
| Epic | Scope and dependencies | Status |
|---|---|---|
| E1 Outline and filters | Ancestor reveal, extension/size/date filters, sort, deep item counts, zero-byte matches | Scoped CI/pixel acceptance across checkpoints; see verification limits |
| E2 Glass and accessibility | Selection/action surface, native filter editor, focus, Reduce Transparency/Motion, minimum layout; VoiceOver features built, speech verification owner-descoped from v1 (2026-10-22) | Underway; full signoff open |
| E3 Volume accounting | Used/free space in the volume header; purgeable space, snapshots, unaccounted space | Volume header built on the development tree on the engine's raw statvfs capacity; Mac verification pending. Purgeable, snapshots and container sharing are Mac-only and not implemented |
| E4 Inspect and remove | Item details and Quick Look, Trash with undo, batch removal and removal history | Built; named check suites passed on Mac (runs 39602481035/39683697776, mocked Trash seam). Real Trash move and real-hardware failure/undo pending |
| E5 Scan control | Persistent exclusions, reviewable unreadable list, Full Disk Access detection | Built: Not scanned list, exclusions editor with unobserved-exclusion reporting (not proof of absence), Full Disk Access detection with an honest unknown state. Named check suites (ExclusionsChecks, FullDiskAccessChecks, SkippedListChecks) passed on Mac in runs 39602481035/39683697776 |
| E6 Duplicates | Rust duplicate finding and review/removal UI | Built: duplicate groups review with per-group removal through the E4 gates. Allocated bytes, not reclaimable space; hard-linked copies called out. DuplicatesChecks/DuplicatesRemovalChecks passed on Mac in runs 39602481035/39683697776 |
| E7 Polish and endurance | App icon, install experience, decimal/binary units, cold first-click investigation, long-session soak/leaks | Icon and DMG install window captured on Mac (run 39602481035) and pixel-reviewed; label-contrast plates merged and the rendered install window pixel-reviewed (run 39683697776); docs refreshed with real Mac captures including the on-disk review popover (run 39690848529, pixel-reviewed). Stability is cross-cutting |

## Release gates across epics
- A REAL Trash move has never executed: every check mocks the Trash/identity seams, so the off-main move, journaling and restore are verified only through injected seams. Close this with a real remove/undo pass on a disposable fixture, then broader Trash failure/undo and real-hardware behavior (volumes, permissions, protected paths). The code-level gates this used to name - off-main execution, per-item identity revalidation, serialized mutation - are implemented; the residual check-to-move window is disclosed in code and can only be narrowed, not closed.
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
