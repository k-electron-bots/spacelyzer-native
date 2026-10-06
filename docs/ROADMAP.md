# Roadmap

Priorities: safety, real and perceived performance, pixel polish, then features. This page describes future work. [Verification status](verification/README.md) describes accepted evidence; [checkpoint history](verification/checkpoints.md) preserves failed and superseded attempts.

## Current priorities
1. Extend the bounded injected focus evidence to actual modified-key/fallback behavior and real-system input. The named boundaries and semantic extension route passed run110, not whole-keyboard or native-graph repair.
2. Ground the cold first-click and typing stalls, compare equivalent release builds and audit UI/FFI/rendering costs, then complete E2 accessibility and real-system validation. Injected preferences or labels are not VoiceOver proof.
3. Prove removal, partial scans, stability and memory behavior on disposable fixtures before a release is called ready.

## First usable release priority
Karim approved safe big-file cleanup first on October3, ahead of hidden macOS space/snapshot/accounting explanations. The feature branch now implements read-only Check on disk, Folders and Largest CSV export, without current UI/runtime evidence. Build useful inspect/preview and reviewed Trash workflows on the existing Largest/outline surfaces. Responsiveness, current-file identity validation, permissions, protected paths, failure and undo gates remain; this direction does not authorize automatic deletion or establish release readiness. The first release uses one-item-at-a-time cleanup with a preview, full path and clear undo; batch cleanup comes later. Hidden-space accounting stays planned after this first usable workflow.

## Near-term steps, in dependency order
Each step names its gate. None is a release-readiness claim, and none authorizes a Mac CI run, a release or spend; the Mac verification gate is owned by the project owner.
1. **Mac verification of the latest branch.** CI128 at `24dff915` passed the Mac engine gate (145 exercised, 5 platform-unexercised, 2 ignored), built production Swift and packaged a DMG. Test-only Swift compilation failed before UI execution; no artifact was uploaded. The correction at `9bc4143` is independently source-reviewed, not Mac-compiled. Needed: a separately permitted bounded run of that corrected version, preserving strict tests and honest skip accounting. [Current evidence](verification/README.md).
2. **Swift consumers for engine work that has no UI (after step 1).** On `item-inspect-engine-stack` only (not main at this audit), the engine has capabilities with no Swift caller; CI128 provides bounded Mac engine evidence, not UI evidence: skipped/unreadable list with a lossy flag (E5), unobserved-exclusion reporting (E5), raw volume capacity (E3), the duplicate finder and `spz_dup_*` ABI (E6), item inspect is now consumed by the branch-only Check on disk popover, with UI/runtime gates still open. For the remaining consumers, order: skipped list view, then exclusions editor, then volume header, then duplicates review (read-only, no removal). Each needs real-UI state capture reviewed by pixels, not source review.
3. **Cleanup workflow (E4).** One-item-at-a-time inspect, preview, full path, Trash and undo, per the owner's October 3 priority. Gates: off-main Trash execution with current-identity revalidation, protected paths, failure and undo on real hardware. Duplicates removal depends on this and on step 2.
4. **Accessibility and input evidence (E2).** Real VoiceOver and real-system input, not injected preferences.
5. **Stability evidence (E7).** Memory plateau over repeated rescans, long-session soak, main-thread stall measurements for hover, typing and expand-all, on release builds. No speed or reclaimable-space claim exists until then.

## Long-range hypotheses (not planned work, no evidence yet)
- Hidden-space accounting: purgeable space, APFS snapshots, container sharing and clone accounting, shown as separate labeled numbers, never merged into one total. Needs Mac-only APIs; unresearched on real volumes.
- Persisted-tree and FSEvents incremental rescan, and index-assisted early results (see the two evaluation pages). Each must prove it cannot show a stale total as current.
- Batch cleanup and removal history, only after one-item cleanup has real-hardware evidence.
- Scheduled or background re-scan reminders, and a "what changed since last scan" view. Both need the persisted-tree work first.
- Cloud/placeholder file awareness (files not materialized locally), and external or network volumes. Need dataless-file and volume-change semantics checked on real systems.
- Distribution (signing, notarization, update channel): requires explicit owner permission and spend decisions; not started.

## Product epics
| Epic | Scope and dependencies | Status |
|---|---|---|
| E1 Outline and filters | Ancestor reveal, extension/size/date filters, sort, deep item counts, zero-byte matches | Scoped CI/pixel acceptance across checkpoints; see verification limits |
| E2 Glass and accessibility | Selection/action surface, native filter editor, focus, Reduce Transparency/Motion, minimum layout, VoiceOver | Underway; full signoff open |
| E3 Volume accounting | Used/free/purgeable space, snapshots, unaccounted space | Feature-branch engine has raw statvfs capacity (`engine/src/volume.rs`, `spz_volume_info_status`, header only, no Swift consumer; bounded Mac evidence is in verification). Purgeable, snapshots and container sharing are Mac-only and not implemented; no UI |
| E4 Inspect and remove | Item details and Quick Look, then batch removal/history | Read-only item review exists on feature branch, UI/runtime unverified; Quick Look, batch and history remain planned |
| E5 Scan control | Persistent exclusions, reviewable unreadable list, Full Disk Access detection | Feature-branch engine side exists; bounded CI128 Mac engine checks are not UI verification: skipped list, exclusions with unobserved-exclusion reasons (not proof of absence). No Swift/UI; Full Disk Access detection not started |
| E6 Duplicates | Rust duplicate finding and review/removal UI | Feature-branch Rust finder `engine/src/dupes.rs` and its C ABI (`spz_dup_*`, header only, no Swift consumer) exist on the feature branch with Linux tests and bounded CI128 Mac evidence (read-only; no UI, no removal path; caps are report-only; sizes are allocated bytes, not reclaimable space). Swift/UI and Mac behavior unverified; depends on E4 for review/removal |
| E7 Polish and endurance | App icon, decimal/binary units, cold first-click investigation, long-session soak/leaks | Planned; stability is cross-cutting |

## Release gates across epics
- Broader Trash failure/undo and real-hardware behavior beyond the narrow disposable CI remove/undo pass. Current MainActor Trash/undo filesystem work and Rust subtree mutation must gain safe off-main execution with current identity revalidation and no concurrent tree mutation/read before cleanup ships.
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
