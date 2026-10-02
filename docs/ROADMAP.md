# Roadmap

Priorities, in order: safety, real and perceived performance, pixel polish, then new features.
"Verified" means checked by the CI demo run (real events posted to the app window on a shared GitHub Mac, screenshots
read by a person). Nothing here has been verified on a personal Mac yet.

## Done and verified on CI
- Rust engine: parallel scan, flat tree, hard-link and firmlink handling, filter, outline projection, treemap layout and hit-testing.
- Windowed outline (no row cap), keyboard navigation, one filter for every view, "No matches" states.
- Selecting a file hidden in collapsed folders expands its ancestors (CI check 19). Extension and maximum-size filters in the UI (CI checks 20-21); modified-date window checked as narrow <= wide (check 22; it does not verify individual mtimes).
- Selection safety: Move to Trash is unavailable when the selection is hidden by the filter or a filter result is pending.

## Underway
1. Verify real Trash round trip on a disposable fixture (in CI), and main-thread stall measurements for hover, typing and expand-all.
2. Largest and Kinds lists moved off the main thread and cached (committed, awaiting CI proof).

## How work is organised
Features are grouped in epics. Tasks inside an epic are thin commits in dependency order, one concern each. CI, tags and releases run per epic (push tag `epic-<n>-<name>`), not per task, to save free-tier quota. Each epic ends with CI assertions plus inspected screenshots before it is called done.

## Epics
1. Outline and filters (E1): reveal ancestors (done, CI 19), extension/size/date filters (done, CI 20-22), item counts (shown in rows wide enough, not visible at the 1024x768 CI window; unverified visually), sort options (Rust sort modes tested; UI check 23 PASS in epic-1 run 37022036702). E1 first run: epic-1-outline-filters (independent review found: zero-byte matches hidden, empty-folder counts missing, screenshots covered by a modal). Epic-1b run 37025735089 (16e7f46): 26 of 28 assertions passed, the two NSMenu item-pick checks failed (menus fill on open); real typing in the ext field passed. Epic-1c run 37030720991 failed: only 26/28 checks reached; the menu driver did not complete. Diagnostic v0.1.89 is not signed off. Consolidated run37036910990 compiled and reached all30 checks: 29PASS, above400 fixture FAIL because width was651pt not401pt. Date/sort/reset effect checks PASS, but exact-step polling skipped later screenshots. Divider targeting and state-synchronous screenshot collection are repaired; new consolidated CI and independent signoff pending.
2. Glass and accessibility (E2): selection bar and buttons, filter field, Reduce Transparency/Motion, minimum window size, VoiceOver labels and tree check.
3. Volume and space accounting (E3): used/free/purgeable, snapshots, unaccounted space.
4. Inspect and remove (E4): details, Quick Look, then batch removal with history (depends on details).
5. Scan control (E5): persistent exclusions, unreadable-location list, Full Disk Access detection.
6. Duplicates (E6): Rust duplicate finder, then UI (depends on E4 removal).
7. Polish (E7): app icon, decimal/binary units, long-session soak and leak check, cold first-click investigation.

## Not verified
Real-Mac behaviour, other window sizes, multiple volumes, APFS clones, purgeable space, VoiceOver.

## Cross-cutting: stability and memory (required before any release is called ready)

Status: v0.1.48 had a crash when a second folder was scanned after a large tree (stale node ids). Fixed in source; regression not yet confirmed by CI.

- [ ] Rescan and tree-swap regression in CI (large then small, cancel mid-scan).
- [ ] Memory plateau across repeated rescans, with measured resident size.
- [ ] Long-session soak with sampled memory.
- [ ] Cancellation and failure recovery checks.
- [ ] FFI bounds checks for node ids; leak check for Rust allocations.
- [ ] CI fails if the app is not running at the end of the demo.

## Evaluated, not scheduled
- E8 Incremental rescan (persisted tree + FSEvents): see docs/EVAL-incremental-scan.md. Not implemented. Spotlight is not used for totals.

- Index-assisted early results and dua-cli progressive traversal: see [evaluation](EVAL-index-accelerant.md). Evaluation only, distinct from persisted-tree/FSEvents repeat-scan work.

- Run37040037876 failed capture1: app-launched screencapture did not create images. Replaced with CI-only state/capture acknowledgement: runner captures using its existing permission, then acknowledges before app state advances. No permission bypass. New consolidated check pending.

- Run37043128105 at c892613 passed all30 checks and captured22 images. Pixel review confirms399/401pt empty/five-digit counts and real date/sort/reset effects. Depth12 evidence is not yet accepted: /tmp vs /private/tmp path mismatch left the large folder expanded. Canonical-path fixture exclusion and explicit visible-depth12 check repaired; independent signoff remains pending.

- Final E1 evidence run also requires actual date, maximum-size and sort choice submenu images23-25, plus an explicitly visible depth12 cell below and above400pt. No separate menu-only run.

- Run37046851306 failed strengthened depth checks at correct399/401 widths: b-large still expanded; choice-menu images23-25 were blank. Do not accept those pixels. Depth fixture now selects nodes by root-child identity instead of path. Menu visual automation remains unresolved; no new checkpoint before that review decision.

## E2 underway, not verified
- First product slice: filter control surface uses macOS26 system glass with macOS14 material fallback and live Reduce Transparency opaque fallback; Reduce Motion disables implicit content animations. Parent/Stop/selection actions and folder chevrons have explicit accessible labels; decorative outline icons/bars are excluded. Awaiting macOS compile, pixels in accessibility modes and VoiceOver/keyboard evidence. E1 submenu/depth evidence remains open and will share E2 consolidated verification, not another immediate harness-only run.


## E2 and E1 consolidated edge checkpoint

Unicode-lowercase name and extension matching now agrees with name sorting (no Unicode normalization or full case folding promised). Filtered Largest and Kinds keep zero-byte matches by item count; zero-area treemap regions remain absent by design. Engine coverage adds empty/missing/file roots, unusual names, sparse and zero-byte hardlinks, inverted/extreme filters, depth and exact parent/name identity, inclusive dates, mixed-case extensions, invalid FFI buffers/IDs and independent reproducers.32 engine tests pass locally on Linux; native macOS execution is pending.

Async filter, outline and derived publication checks cancellation, generation and tree identity inside the main actor. Scan progress/completion checks scan generation and session identity. CI adds token-specific barriers that hold old computed work across newer-filter completion, tree clearing and a different arena with reused node IDs, then verify completion did not replace current state. This is uncompiled and unexecuted until the macOS checkpoint, not race signoff.

The consolidated checkpoint expects44 assertions and30 captured states, including actual submenu attachment, exact large-folder exclusion and depth12 projection, light/dark minimum960x600, injected live Reduce Transparency/Motion toggles, keyboard selection and restoration. Pixels still decide: prior E1 submenu/deep images failed. Injected environments are not OS preference or VoiceOver proof. No E1/E2 completion or release-readiness claim before independent review. Permission-denied/mount/volume races, leak accounting, real VoiceOver, accent normalization and real hardware performance remain open; no exhaustive-edge claim.


Run94 (abdf1e8) passed engine jobs but stopped at Swift compilation: NSMenu.isAttached requires a call, and system accessibility environment keys are read-only. The repair uses optional, writable SPZ_DEMO override keys; nil inherits live OS values in normal operation. No UI screenshots or race runtime results came from run94. The repaired consolidated checkpoint is still pending; E1 and E2 stay open.


Run95 passed engine jobs and stopped at Swift compilation because NSMenu.isAttached() is unavailable on current macOS. Removed the unavailable API; parent highlighted identity is a tracking diagnostic only, never submenu visibility proof. Actual submenu pixels remain mandatory and unverified. No runtime evidence/artifacts came from95. Added two controlled real-session overlapping scan regressions: old progress and old completion are held while a newer scan completes, then released; identity, revisions, bytes/items, elapsed/result time, error and scanning state must remain current. Pending macOS execution. Next combined scope is46 assertions/30 images and32 engine tests, no exhaustive testing or readiness claim.


Independent source review caught a progress-barrier false-positive: multiple callbacks share one scan generation. Every publication now carries a unique UUID; after-hook completion must identify the parked invocation, and each regression checks that it is incomplete before release. Replacement-root expectation comes from the previously scanned replacement Tree.path(0), with non-nil checks, not independent path normalization. Source review/runtime remains pending;46 assertion scope unchanged.


Run96 at eb2010d compiled the universal Swift app and passed32 engine tests on Linux/macOS.46 UI results:43 PASS,3 FAIL. All6 UUID publication barriers passed, including overlapping real scan progress/completion.30 images exist. Exact large-folder exclusion/depth12 projection and actual399/401 deep/empty/10,001 count checks passed; inspected images show the deep rows and aligned counts. Five E2 mode/labels/keyboard/restoration checks passed with injected preferences; source and injected modes do not prove real OS notifications or VoiceOver.

Remaining failures are submenu tracking23/24/25 (highlighted=nil). Actual screenshots show only root filter/sort menus, no choice submenus. E1 remains open and no release-readiness claim is made. Independent artifact review is pending. Do not weaken this gap into root-menu/source/effect coverage; no immediate harness-only full rerun. Artifact: https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37057037990/artifacts/11249012822 . This is diagnostic CI evidence, not a delivered release.


Next substantive E2 slice, committed but uncompiled/unverified: folder counts use selected control text on emphasized rows, secondary text normally and primary label with Increase Contrast. Native display-options notification and effective-appearance change refresh the cell colors. Full path tooltips preserve deep-name identity. CI-only contrast override is ignored in normal operation. Plan selected/unselected light/dark/increased-contrast images31-34; log alpha-composited semantic-color contrast against a background proxy, not a rendered WCAG verdict. Minimum check now verifies960x600, with narrow Tab/focus, Escape/no-effects and single-selection contracts. These do not claim a complete AX tree, actual OS preference notifications, motion behavior, older-macOS fallback or VoiceOver.

The failed submenu action dispatch is replaced in the pending harness by native tracked-menu down/right keyboard events; parent highlight remains diagnostic only. Actual choice submenu pixels are still required. Planned consolidated scope53 assertions/34 images; no new checkpoint until independent source review and parent coordination.


Independent source review accepts count color refresh/reuse, not runtime. Focused harness corrections: Tab must reach the next visible key-view identity (or its field editor), Escape starts without pending removal/message and preserves both, submenu navigation normalizes with Home then counts only enabled/nonhidden selectable items. Actual focus/menu pixels and runtime remain pending.53-check/34-image scope unchanged; no real OS, motion, AX-tree or older-OS signoff.


Run97 at50b0235 compiled/passed engine jobs and captured34 images.49PASS/1FAIL of50 written, expected53. Actual choice submenu pixels23-25 now show date/max/sort options; tracking diagnostics pass. Count selected/unselected light/dark/injected Increase Contrast contracts and pixels31-34 pass narrow scope, independent review pending. Sampled repeated core count-ink contrast versus adjacent flat background: selected light5.430/dark6.235, normal light3.949/dark5.925, increased light14.353/dark12.274; not a formal compliance/every-antialiasing-edge guarantee.

Minimum-height assertion failed: measured contentView960x652, not960x600. Need authoritative layout-content/root measurement, not width-only acceptance. Final Tab/Escape/single-selection assertions did not reach file because runner killed app immediately after capturing34. App alive at end/no crash artifact. Explicit demo-finished handshake repaired in source, unexecuted; final focus checks remain unverified. No immediate harness-only rerun/readiness. Artifact https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37060726827/artifacts/11250503094 .


Independent scoped E1 acceptance is achieved across checkpoints through run97 submenu choice pixels; this is not whole-run97/E2/release approval. E2 selected-count readability and injected branch layout accepted visually; raw contrast audit now preserves originals, fixed crops/background coordinates, full qualifying-color frequencies and executable method for independent reproduction, not formal compliance.

Next product refinement, pending source review/runtime: unselected count uses primary labelColor universally; selected count retains selected control text. Size/path hierarchy remains separate. Inactive selection and row reload/reuse color contracts/screens35-36 planned. Minimum check measures actual SwiftUI root and contentLayoutRect against960x600 while logging contentView/chrome separately; raw960x652 does not waive600 layout fit. Explicit demo-finished handshake waits for final focus assertions before teardown. Planned55 assertions/36 images; no CI or readiness until coordinated checkpoint. Actual OS, motion, olderOS and VoiceOver gaps remain.


Independent cumulative source review accepts fail-closed final handshake and minimum root/layout logging, runtime still decides. Inactive/reactivated selection checks now preserve model-node/table-row identity before/after focus changes. State36 is visible reload/reselect color evidence, not offscreen recycled-cell reuse; named accordingly.55 assertions/36 states unchanged, pending coordinated checkpoint. Offscreen reuse, actual OS and full E2 signoff not claimed.


Run98 at12a251f compiled and passed engine jobs.53PASS/2FAIL of55,36 captured states, final completion handshake worked. Root960x600 and contentLayoutRect960x600 passed while contentView960x652 includes unified chrome; actual26 fit pixels await independent review. Primary count31-34 and inactive35 branches pass narrow color/identity contracts. Visible reload36 and exact Tab destination fail.36 shows gray inactive selection after reactivation, so do not claim active reload color coverage or blame product focus without responder/key-window evidence. Escape and single-selection final checks pass. Add explicit responder/window/node/row diagnostic details before next coordinated slice, not an immediate harness-only rerun. E1 accepted across96/97 and new menu regression checks pass, not full E2/release approval. Artifact https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37064592633/artifacts/11252766224 .


Next substantive consistency/safety slice (uncompiled/unexecuted): Swift now uses existing spz_filter_count for filter membership. Previously SelectionBar and removal guard treated zero allocated bytes as outside-filter, wrongly warning/blocking matching zero-byte files even though outline/Largest kept them. New disposable zero-byte fixture checks count1/bytes0, hidden nonmatch refusal, matching confirmation and one mocked Trash call; no user files are touched. Pending56-contract/36-image checkpoint, not permission to remove anything without confirmation.

Treemap async publication now checks cancellation, generation and current tree/root/filter/size inside main actor, invalidates on disappear, clears hover on relayout and rejects interactions/readouts from stale root/filter/size or foreign-tree layout. Previous picture may stay visible while new same-tree layout computes, but cannot select from stale coordinates. This is source hardening, not reproduced runtime race or deterministic treemap barrier proof yet. Existing32 engine tests pass locally, no engine behavior changed. Focus diagnostics include selected cell backgroundStyle; failed Tab/active reload expectations unchanged pending real responder diagnosis. No CI run yet, E2/release remains open.


Independent source review accepts count-based zero-byte membership semantics with pending/protected guards unchanged, mocked Swift execution pending. Treemap repair also stamps model.revision, rejecting in-place forget mutations before relayout. No-matches overlay uses only current layout and a settled filter, so an old empty layout cannot claim the new filter has no matches. Still source-only treemap acceptance, not one of six previously proven cache interleavings. Focus failure causes remain diagnostic/open. No readiness.


Treemap zero-area semantics repair: settled current layout with no rects shows No matches only when activeFilter.count(displayedRoot)==0. Matching zero-byte-only items instead show a truthful no drawable allocated space state, directing to outline/Largest. Root-local count, never global filter count, owns this distinction. Disposable zero-byte fixture asserts root count1 with zero rects and excluded-file count0.57 planned contracts; Swift runtime/pixels pending, no CI or readiness claim.


Independent38b271d source accepts root-local zero-area distinction and retained guards. The fixture assertion is named zero-match-root-count-and-layout-data-contract: it proves count/rect data, not an instantiated SwiftUI zero-area message or pixels. Combined checkpoint includes mocked zero-byte removal regression and unchanged two failing focus/reload contracts with more diagnosis.57 results/36 states, no source-only E2 or treemap race proof/readiness.


Run99 at554321c compiled/passed engine jobs.55PASS/2FAIL of57,36 images, app alive/final handshake complete. Both zero-byte fixture contracts pass: rootcount1/rects0 data, matching warning/removal policy confirms once through mock while nonmatch stays blocked. This is not SwiftUI zero-area-state pixel proof. Treemap revision/current gates compile, not forced-interleaving race proof.

Same two focus gates fail with useful diagnostics: visible reload key=false despite makeKeyAndOrderFront, preserved node1/row0, inactive labelColor. Tab key=false, intended nextValidKeyView=nil, responder becomes SwiftUIOutlineListView and selection remains1. Active restoration precondition and exact intended Tab destination are absent; cause/product defect not established. Expectations remain unchanged. Full36 shows neutral readable inactive selection; date submenu23 remains visible. No immediate harness-only rerun, E2/release not approved. Artifact https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37067135227/artifacts/11253697318 .
