# Linux model-layer harness (not Mac evidence)

Compiles and runs the REAL `AppModel.swift`, `Engine.swift`, `BatchRemoval.swift`, `OutlineSelectionSync.swift`, `CSVExport.swift` and `MultiSelectChecks.swift`
on Linux (Swift 6.0.3) with stubs for AppKit and UniformTypeIdentifiers, a harness `Check`, and a C stub for `spz_engine_panic_count`
(returns 0; every other engine C symbol is left unresolved, so any check that reaches the Rust engine crashes rather than passing).

Stubbed or replaced, not real: AppKit types (empty classes), UTType, `QuickLookController`, `DuplicateRemoval`, `IdentityVerdict` (copied verbatim from
ItemReview.swift by the build script), and the `trashItem` default closure (Linux Swift 6.0.3 crashes compiling the original; the build script replaces
exactly that closure). What this proves: model-level logic (selection, set/focus rules). What it cannot prove: AppKit/SwiftUI behavior, the Rust engine,
AX, layout, pixels, or anything on macOS.

    scripts/linux-model-harness/build.sh <out> [sources-dir]   # build
    scripts/linux-model-harness/compare.sh baseline                          # all declared checks pass on HEAD (NOT fix proof)
    scripts/linux-model-harness/compare.sh regress <base-ref> <check>      # <check> fails on base AppModel, passes on HEAD, nothing else differs

Needs a Swift 6.0.3 Linux toolchain on PATH (SWIFT_BIN=/path/to/usr/bin) and clang.

## Real-engine folders/derived checks

    scripts/linux-model-harness/compare-engine.sh <base-ref> <failing-check>[,<failing-check>...]

`build-engine.sh` links the real Rust engine (`cargo build --release` staticlib; needs rustup, installed with `rustup-init --profile minimal`) and compiles `foldersChecks()` sliced verbatim out of `SpacelyzerApp.swift` (the AppKit UI file itself is not compiled). The Rust macOS scan path (`scan_macos.rs`) is not exercised: the Linux scan path builds the tree. `compare-engine.sh` is a gate: on `<base-ref>` exactly the named checks must fail, every declared check must be emitted, and HEAD must pass all of them. A crash, a missing DONE line or any other exit code fails the gate.

## Real-engine model checks (broad)

    scripts/linux-model-harness/build-engine-checks.sh <out> [sources-dir]

Like `build-engine.sh`, plus real code sliced verbatim (no edits) out of the SwiftUI view files and compiled without SwiftUI: `DuplicateRemoval`, `DuplicatesModel`, `SkippedListModel`, `VolumeHeaderModel`, `FullDiskAccessStatus/ProbeOutcome/Model`, `ExclusionEditing`, `ExclusionsModel`, `OpenGate`, and the non-view part of `ItemReview.swift` (`IdentityVerdict`, `ItemReviewResult`, `ItemReview`, `ItemReviewModel`). `ObservableObject` and `@Published` are inert stubs (no change publishing is exercised). It runs these real suites against the real Rust engine (Linux scan path): `foldersChecks`, `MultiSelectChecks`, `BatchRemovalChecks`, `BatchRemovalExecutionChecks`, `BatchUndoChecks`, `IdentityGateChecks`, `OutlineSelectionSyncChecks`, `DuplicatesRemovalChecks`, `DuplicatesChecks`, `SkippedListChecks`, `VolumeChecks`, `FullDiskAccessChecks`, `ItemReviewChecks`, `ExclusionsChecks`, `RemovalHistoryChecks`. Not Mac evidence: AppKit/SwiftUI rendering, scan_macos.rs, AX, layout, pixels. `QuickLookChecks` and `QuickLookBatchChecks` are not compiled here (QuickLookController is stubbed).
