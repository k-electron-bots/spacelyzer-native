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
for app/process/deletion/verdict, but consumes the shared whole-job deadline, but artifact-upload reserve is not a measured service guarantee. The standalone runner now requires an absolute whole-job deadline and refuses before any fixture work unless the full segment plus at least120s artifact reserve fit; the explicit technical-hardening workflow now supplies that deadline. The app shares a150s work deadline under its180s cap, reserving30s for sampler flush/PNG/verdict/exit. These are fail-closed ceilings, not measured durations. No combined35min fit or readiness claim exists.

Before an execution request: independent review of the integrated source, sampler flush,
filter/layout identity and bounded cleanup; a defensible shared35min budget; then a separate
explicit execution approval. No repeat or retry is authorized by this document.

## Explicit technical-hardening mode (source only)

`technical_hardening=true` is a new exclusive mode. All other boolean inputs must be
false. Existing consolidated/default modes are not redefined. It retains normal shipping
build and helper typecheck, isolated CI engine/test Swift, Rust, failpoints, bulk, ordering
including real Trash/cancel, all178 demo UI checks and their81 mounted captures, and scale.
It omits signing-identity import, DMG/package, Finder install/icon evidence and docs-tour
captures. The informational shipping welcome/size/scanning screenshot preamble is omitted;
the full scripted UI demo and assertion checks are unchanged. No release path runs.

The first Mac step anchors the35min clock. Scale admission requires its360s segment plus
120s artifact reserve. Main functional and scale artifact uploads are required by a separate
fail-closed technical gate, alongside every functional suite. A refused scale admission is
failed/incomplete evidence, never a successful readiness verdict. PNGs still need pixels
inspected after execution. This mode is not enabled or dispatched by publishing source.

Exact eventual inputs, only after independent review and explicit new execution approval:
`technical_hardening=true`; `compile_only=false`, `consolidated=false`, `docs_only=false`,
`perf=false`, `perf_in_run=false`, `docs_2x=false`. Pin the approved commit, no retry, one
35min job. Previous consolidated approval/input examples do not authorize this mode.

Timing estimate is not fit proof. The last functional job39683697776 took25m36s. Its
548s launch/demo step is preserved except the informational preamble's explicit116s sleeps.
Docs115s plus packaging25s/Finder18s/sign-import1s and the early DMG upload1s are removed. The old job subtotal1536s minus276s named removed work plus360s scale ceiling and120s artifact reserve is1740s (29m), leaving360s to the hard cap for new unmeasured costs and variance. This is a planning estimate from one older run, not a measured new-mode bound. Scale adds up to360s;
isolated universal CI engine build and changed real Trash/ordering costs remain unmeasured.
A ceiling/admission fallback does not make those new costs measured. Do not describe this as
ready for a scarce run until the primary saved-step totals and unmeasured allowance are
reviewed with the exact workflow. No Mac compile/runtime or visual PASS exists at this head.
