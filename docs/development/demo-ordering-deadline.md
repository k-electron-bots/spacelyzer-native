# Proposed same-run demo + ordering validation

Preparation only. No Mac run has executed this route. The workflow remains disabled
until separate owner approval. No release, spending or retry is authorized here.

Keep the 2100-second job and 720-second shared compile budget. Preserve the early
always-upload demo/capture artifact before attempting required ordering. Ordering
starts only with at least 690 seconds left: 330 seconds for setup/signing, fresh
unique-bundle execution and process cleanup; 160 for artifact/gate work; 200 for
teardown. Its cutoff is min(now+330, job deadline-360). Insufficient time is a
required FAIL/INCOMPLETE, never an optional pass. The ordering artifact upload has
a two-minute cap and is always attempted; the final gate requires both ordering
and that upload to succeed.

The copied, ad-hoc signed test bundle gets a unique bundle identifier and fresh
fixture/results. Prior Spacelyzer processes must be absent before launch. The
runner uses the existing Mac-proven `open -n` route with stdout/stderr and explicit
environment arguments. Its launch acknowledgement is not success: fresh exact
result and assertion manifests are required before the cutoff. The existing OrderingDriver runs
unchanged: 166 exact required names, no missing/duplicate/unlisted/failing result,
300-second internal watchdog. The outer330-second work deadline reserves5 seconds
for process cleanup. Partial result/stdout/stderr evidence is retained on errors.
Demo's app-alive check and ordering's intentional exit are distinct end states.

Measured prior ordering was55/56 seconds for159 checks, not the current166.
Run39947043378's listed core steps sum851 seconds; its job was14m32s, but its final
evidence gate failed. Neither historic timing proves this prepared route fits.
Worst-case existing demo/capture caps leave insufficient tail: late admission must
fail honestly, retaining already-uploaded evidence rather than skipping checks.

Linux controls execute690-second admission boundary/refusal, result-name negatives,
open launch failure, crash/timeout/missing-result partial retention, workflow required-gate
failure/skip/cancel paths, and unchanged compile/job budgets. They do not prove
AppKit launch behavior, native helper AX success, Mac checks or screenshot pixels.
