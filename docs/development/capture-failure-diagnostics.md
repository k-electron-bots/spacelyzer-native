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

Run 40098663789: AX setAXSize asked 1280x800 and the window stayed 992x665 (screen 1024x768, visible 1024x677). A rect capture of a 1280-wide window gives a display-clipped 992-wide image.

The candidate keeps the same PID and history entry. The cleanup session is launched with `SPZ_SIZE_REQUESTS=1`; a CI-only responder sizes the main window through the app's own path and reports pid, token, window count, sheet state, frame and visible height. Required wide stages, each judged against the REQUESTED 1280 (never against another measured value):

- `resize`: app report frame width 1280 +-2; frame height min(800, visible height) +-2 (height rule pending review); same pid, echoed token, one ordinary window, no sheet.
- `bounds-width`: WindowServer bounds width of the main window 1280 +-2.
- `image` / `image-width`: `screencapture -l <main window id>`; PNG width 1280 or 2560 +-2.
- `image-content`: SMOKE check only (right-most 200 columns hold at least 8 distinct colours). It is not content proof; native pixel review stays the gate.
- `popover-image` / `popover-nonempty`: a second window image exists.
- `content-after`: AX still sees "Backup 2025.zip" after the images were taken.
- `bound-windows`: main and popover window ids are listed both before and after the captures.

The end state is captured only when all of these passed. Unverified natively: that `-l` renders the off-display part, that the popover is listed and capturable, and that the history button stays AX-pressable off-display.

Test-suite execution evidence: scripts/test-v1-capture.py has its structural guard (single top-level exit, last statement) at the top and an executed-check floor; scripts/test-suite-exec-guard.py proves a mutated suite with an early exit is rejected. Both run in the Linux preflight.
