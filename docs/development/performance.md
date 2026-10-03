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
