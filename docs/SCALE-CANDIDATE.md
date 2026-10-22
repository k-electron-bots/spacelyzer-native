# Mounted scale candidate

Status: source candidate. Swift uncompiled and unrun on macOS. No execution permission
is implied. The workflow does not launch the scale mode. The normal test app compiles it.

## Scope

The same test binary accepts `SPZ_CHECKS=scale`. It uses the mounted app scene, actual
AppModel scan, outline/derived publication, expansion to1,000,002 table rows, a realized
last-row cell, exact single-file filter, clear/restore, and the mounted treemap's actual
published tree/filter identities and valid hit. It requires a PNG for later pixel inspection.
No test result substitutes a synthetic million-item tree.

The runner creates and verifies the existing `expansion-1m` profile:1,000,005 scan nodes.
The profile uses sparse files. The runner writes the single byte of its1-byte filter target
and restores mtime before inventory verification, so allocated-byte treemap layout/hit is
nonempty. Other file sizes/mtimes remain the generator's expected inventory.

A test-only sampler permits one outstanding main-queue ping, stops enqueue under lock,
flushes prior pings with a main-queue sentinel and requires at least10 completed samples.
Peak<250ms is a provisional coarse scheduling-delay guard, not a p95/input latency SLA,
CPU-cause finding, smoothness guarantee or real-hardware signoff.

`run-scale-check.py` uses an already-built test app, a fresh directory under RUNNER_TEMP,
a unique direct child PID, bounded generation/verification/app/deletion, and exact five-name
verdict checking. Artifacts remain; fixture deletion must finish before segment PASS.
Missing/duplicate/failing assertions, missing PNG, empty metrics, bad result header and
Linux execution have executed failure controls. PNG signature checking is not pixel review.

## Cancellation coverage

The separate Rust real-FFI regression uses a serial directory chain with1000 files per
level. It parks at the third directory only after2002 real prior entries were accounted,
calls actual cancel+release, rejects expiry, requires<5s coarse completion, checks exactly
2003 partial nodes, then verifies an independent full3003-node scan. Removing cancel or
parking prematurely fails executed controls. This is bounded work-progress cancellation,
not mounted Stop/input dispatch or interruption of one huge directory's enumeration.
The existing Swift suite still covers the43-node pre-first-enumeration path only.

## Budget is unresolved

Previous macOS job:25m36s. New CI universal-engine build and real Trash costs are unmeasured.
Scale's default360s is a hard ceiling, not measured fit. It reserves210s after generation
for app/process/deletion/verdict, but does not yet consume a shared whole-job deadline or
reserve measured artifact-upload time. No combined35min fit or readiness claim exists.

Before an execution request: independent review of the integrated source, sampler flush,
filter/layout identity and bounded cleanup; a defensible shared35min budget; then a separate
explicit execution approval. No repeat or retry is authorized by this document.
