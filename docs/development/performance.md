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
