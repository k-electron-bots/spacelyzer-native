# Scoped performance measurements

These are historical observations from the early interface checkpoint, retained for context. They are not a current benchmark suite or a claim that a competing app is slower.


All from a shared GitHub Actions Mac, one folder (`/Library`, 153k items). Informational, not a benchmark. No comparison
with any other disk analyzer has been run, so no speed-up claim is made.

| What | Rust engine | Notes |
|---|---|---|
| Scan, 153k items | about 2 s wall | includes disk and OS cache effects |
| Filter by name, 153k items | 10-20 ms | 1M synthetic nodes on a 2-core Linux box: 8-28 ms |
| Treemap layout, 215 rects | 0.1 ms | plus 0.05 ms to copy into Swift |
| Outline projection, 153k rows (everything expanded) | 18 ms | rows reach the UI in 40-106 ms after the windowed outline; 16.9 s before it |

The last row is how long until the rows arrived on the main thread, not a full redraw measurement.
Engine timings are reported separately from UI and copy timings.


Repeat-scan and early-results proposals are in the [incremental](../EVAL-incremental-scan.md) and [index-assisted](../EVAL-index-accelerant.md) evaluations; neither is implemented.

## Run110 ungated interaction measurements

Shared CI Mac, October 2, 2026: first-click post-to-selection2,096.7 ms and main-thread stall2,093.2 ms; later click37.6 ms; typing/filter-arrow stall316.2 ms; 40-arrow p50/p95/max35.7/74.6/117.3 ms; hover0.7 ms. These are outside the 80 green functional assertions, not a performance pass or proof of regression. The existing broad sample window does not isolate cold-click causality. Separate event dispatch, native selection callback, model publication and view updates before changing the product or claiming smoothness. [Evidence](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37092313793/artifacts/11263786545).

## Run111 sampled stages, not a performance win

Cold260.9ms/stall252.8ms, later42.3ms; 40-arrow p50/p95/max18.6/187.4/787.6ms and stall789.6ms; typing/filter-arrow stall162.1ms; hover0.6ms. Buffered click stages place about202ms before tablemouseDown, about2.65ms inside it and about0.2ms in the callback/model assignment. The8s5ms sampler identifies the correct process/version and exits0, but no wall/uptime bridge proves overlap and no aggregate stack has chronological assignment. The later workflow completion timestamp is not sample-end time. These mixed profiler-perturbed CI numbers, with existing synchronous log I/O, are not an overall improvement or causal proof. [Evidence](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37094174463/artifacts/11264190402).

## Run112/113 temporal diagnostics and changed arm conditions

Run112 PID/header bridge puts rawheader283.47ms after tracebegin, beyond the115.5ms selection wait. Startupack is not sampling readiness. Nativecallback95.1ms, warm34.5; arrow34.2/296.8/553.5ms p50/p95/max,stall548.1,typing261.8,hover0.5.

Run113 adds explicit1s async idle settling before reset/input, no input/product prewarming. This alters the arm and removes cold comparability. MatchingPID21499/rawheader05:11:36.179UTC precedes trace05:11:37.072619UTC by893.619ms. Subprocessend05:11:45exit0 includes symbol/report processing, not last-sample time. The requested8s5ms command and temporal bracket do not supply per-stack chronology. Selection wait821.2/stall821.9ms versus nativecallback120.845ms and outlineupdate470.492ms; arrow18.9/140.9/429.2ms p50/p95/max,stall137,typing111.9,warm24.5,hover1.3. No overall improvement or causal frame attribution.

[Run112 evidence](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37096739621/artifacts/11264119652) · [Run113 evidence](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37098640048/artifacts/11265437495).

## Run114 settled diagnostic arm

PID11681/version114 rawheader06:08:05.410UTC precedes pairedtrace06:08:06.966780/.9667811UTC by1556.78ms. Subprocessend06:08:14 includes report processing, not last-sample time; workflowwait06:11:21 is later. Requested8s5ms/coarse temporal alignment only, no per-stack chronology or cause assignment. Selectionwait1279.1/stall1273.9,warm26.6; arrowp50/p95/max34.0/76.4/768.2ms/stall766.9,typing264.2,hover1.0. The1s idle settling arm changes cold conditions; mixed shared-runner measurements do not establish an overall win. [Evidence](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37101601436/artifacts/11265798604).

## Run115 diagnostic arm

PID11509/header07:02:23.977UTC precedes trace07:02:24.8409882 by863.9882ms. Subprocessend07:02:33exit0 includes processing; requested8s5ms is not a first/last-sample chronology. Selection185.5/stall205.5,warm38; arrowp50/p95/max18.7/175.3/765.5ms/stall761.3,typing240.1,hover0.9. Same alteredidle arm/no cold comparison or overall performance claim. [Evidence](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37104425688/artifacts/11267976189).

## Run116 diagnostic arm

PID23733/rawheader08:05:03.198UTC precedes trace08:05:04.1193771/.119378 by921.3771ms. Subprocessend08:05:12 includesprocessing; requested8s5ms/coarse bracket only,not first/last-sample or causal stack chronology. Selection614.7/stall609.1,warm53; arrowp50/p95/max15.9/54.7/488ms/stall486.6,typing260.9,hover0.4. Alteredidle/no cold comparability or overall win. [Evidence](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37108069847/artifacts/11269385250).

## Run117 diagnostic arm

Selection1284/stall1278.4,warm54.7; arrowp50/p95/max17.1/35.1/332.6ms/stall280.8,typing161.6,hover0.5. Altered1s idle settling arm/sharedrunner/profiler perturbation prevents original-cold comparison; no overall win or causal stack attribution. [Evidence](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37109813090/artifacts/11268988193).

## Run118 diagnostic arm

Selection708.9/stall708.3,warm57.9; arrowp50/p95/max37.6/109.2/575.3ms/stall569.1,typing211.1,hover0.2. Altered1s idle settling arm/sharedrunner/profiler perturbation prevents original-cold comparison; no overall win or causal stack attribution. [Evidence](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37111144701/artifacts/11269359238).

## Run119: substantial stalls still unresolved

Selection1575.4/stall1570.3,warm45.4; arrowp50/p95/max28.2/104.9/1451.1ms/stall1455.3,typing278.5,hover0.9. Altered1s idle settling/sharedrunner/profiler perturbation prevents original-cold comparison. No overall win or causal stack attribution. Next work should ground event queue/native dispatch/model/view publication paths with focused causal evidence before optimization; green safety assertions do not clear these stalls. [Evidence](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37115126519/artifacts/11271710264).

## Run120: causal envelope coverage remains incomplete

[Run120](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37116511862) at source `a941c25` compiled on Linux/macOS, including the external client. Whole result: 90 PASS / 1 FAIL of 91 checks, 48 states; release skipped. The native footer accessor remains the sole failure. The separate external same-node exact Help+Value regression passed. No new product safety or performance acceptance follows.

Both diagnostic phases installed and removed their monitor/observer with zero recorded drops, identity-cap loss, collisions or ambiguous lookups. However, click and 31 of 40 arrows have unmatched exact timestamp identities. Only nine arrows have full exact-associated stage chains. Outbound/delivered timestamps differ by fractions of a nanosecond, consistent with representation quantization, but its mechanism is not proven. Do not retroactively relabel unmatched records. Model/view context is heuristic; common-mode runloop observations and queued-probe delay do not prove CPU-busy time or sleeping time. Buffered flush is included before stall summaries.

PID17849 bridges place click at 10:37:30.708123 to 31.9608235Z and arrows at 10:37:31.964457 to 35.453766Z. The raw sampler header is 10:37:29.742Z, with an eight-second sampling command and subprocess end at 10:37:38Z. This is coarse temporal overlap for both phases, not per-stack chronology or exact per-event sampler coverage.

Diagnostic click243.3ms/stall235.2ms, warm34.5ms; arrows p50/p95/max17.6/83.1/909.3ms, stall908.6ms; typing202.2ms, hover0.5ms. Shared-runner, altered-idle, profiler and instrumentation effects remain. No original-cold comparison, clean benchmark, overall win or CPU cause. Pixels8/48 inspected: selected outline row readable and unmount placeholder has no returned old layout. Existing narrow safety boundaries remain unchanged. Next work is prospective diagnostic identity repair, reviewed before landing, not optimization.

[Artifact](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37116511862/artifacts/11271722675) includes the raw envelope and unchanged failure evidence.

## Run121 and run122: prospective normalized diagnostic identity

Run121 at `8ee2f15` failed Swift compilation before UI execution: nested Expected.matches called the actor-isolated pure timestampBin helper synchronously. Linux passed33 tests; no UI artifacts or91/48 runtime result. Run122 at `88aeb4d` marks only this pure argument/local-arithmetic helper nonisolated; shared monitoring and buffering state remain on MainActor.

[Run122](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37121764101) compiled Swift/client and passed Rust33 tests. UI90 PASS /1 FAIL of91,48states. Native footer accessor remains failed; separate external exact Help+Value regression passed. Artifact publication is not release acceptance.

Independent raw-envelope review accepted the prospective normalized injected arm: click1/arrow40 have post, monitor, native handler, assignment, outline update, SwiftUI selection, probe and driver records. Both monitors/observers installed and cleaned; zero drops, identity loss, collisions, ambiguous lookups or invalid timestamps. Normalized lookups3click/99arrows, all41 driver polls changed selection without timeout. This is rounded-microsecond singleton-tuple attribution only, not raw timestamp identity, general event identity, proven timestamp-conversion mechanism or retroactive relabeling of run120. Bin boundaries can split close timestamps; unrelated inbound same-tuple events remain indistinguishable. Model/view context remains heuristic.

Click post-to-monitor332.768ms, monitor-to-table311.422ms, table handler1.347ms, driver59.063ms after assignment. Arrow0 handler2.249ms, driver619.936ms after assignment. Queued probes measure main-queue opportunity, not dispatch latency. Common-mode runloop gaps include actual handler/update records inside them and do not prove sleeping or CPU-busy time. Chronology-bearing profiling is needed before optimizing.

Mixed click704.6ms/stall700.9ms,warm30.0ms; arrows p50/p95/max17.6/41.6/738.1ms,stall737.8ms; typing150.6ms,hover0.5ms. Alteredidle/sharedrunner/profiler/instrumentation and buffered flush limits remain; no clean benchmark or overall win. PID19240 raw sample header12:14:45.286Z precedes click12:14:46.083592Z and arrows12:14:47.801996Z;8s command/subprocess end12:14:54Z gives coarse temporal overlap, not per-stack chronology. Pixels8/48 inspected: readable selected row and no returned treemap behind the unmount placeholder.

[Run121](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37120426167) · [Run122 artifact](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37121764101/artifacts/11273437286). Native failure,120 missing exact identities and prior narrow safety boundaries remain unchanged.
