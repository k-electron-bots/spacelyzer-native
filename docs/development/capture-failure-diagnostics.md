# Capture failures and independent phases

This local instrumentation is grounded in run40050466225, not native proof of
the new runner. It changes no product behavior or acceptance criterion.

The run retained AXWindows -25204 but no independent app attribute responses;
the wide resize retained "dimensions not observed" without actual dimensions.
Those errors identify failed operations, not necessarily their underlying cause.

The v1 runner now has preparation followed by independent exclusions, duplicates,
cleanup and FDA phases. Each fresh app phase depends only on safe disposable
fixture preparation, never on an unrelated phase succeeding. They execute
sequentially to avoid interference between app instances, but their pass/fail
dependencies are independent. Total remains165s inside the existing3min step.
Phase ceilings15/22/35/65/25s bound one stalled phase; actual calls and diagnostics
share those ceilings. A global deadline can still block later stages, explicitly
recorded rather than called a pass. No new run is authorized.

Preparation failure blocks app phases. Confirmation or scoped target failure
blocks destructive press and downstream cleanup content. Compact history failure
blocks same-session wide history. Missing required images are recorded as
blocked endstates with the causal phase, not as executed checks. Independent FDA
and other capture phases continue. No unsafe "continue anyway" mutation.

Every phase retains argv, stdout/stderr, return code, duration and timeout or
blocked reason, flushed while running. Each ordinary AX helper invocation retains
its own exact arguments/response/rc, including stderr a caller otherwise hides.
The final aggregate includes all failed and blocked phases, required visible
endstates, and remains red if any required criterion is missing. Captured images
are labeled captured-unreviewed until pixel inspection.

The wide substage additionally records read-only geometry and snapshots even
when resize or opening fails. Dependent open/content/image actions require
successful preceding state; action statuses are not visible-content proof.
Resize prints requested, before and actual dimensions, AX operation/read/set
codes and actual screen frame/visibleFrame. These observations can demonstrate
clamping or refusal when it occurs, not assume it from screen size alone.
The external probe retains target/client PID, trust and failed operation code,
and independently tries app role/title/focused/main/children after AXWindows
failure. Those diagnostic replies cannot satisfy the sheet identity gate.

Real Linux fault injection executes the real v1 scripts with declared AX/process
seams: multiple independent failures remain visible, FDA/duplicates still run,
no invalid destructive action runs, missing history is blocked, timeout keeps
partial stdout, and the final gate stays red. This is real runner logic proof,
not a native SDK, AX, SwiftUI, geometry or pixel result. No promise that every
future failure can reveal a root cause; missing observability remains explicit.

## Wide history: in-session size and window-id capture (candidate, native-unverified)

Run 40098663789: AX setAXSize asked 1280x800 and the window stayed 992x665 (screen 1024x768, visible 1024x677); a rect capture of a 1280-wide window yields a display-clipped 992-wide image. The candidate keeps the same PID and history entry, asks the running app (CI-only, `SPZ_SIZE_REQUESTS=1`) to size itself, and judges the app's own report: frame width must be 1280 +-2; frame height must be min(requested, visible height) +-2. Images are taken per window by id (`screencapture -l`); the main-window PNG width must equal the frame width at 1x or 2x, and a popover window image must exist. Whether the OS renders off-display window parts for `-l` is not verified.
