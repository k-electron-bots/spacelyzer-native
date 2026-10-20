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
