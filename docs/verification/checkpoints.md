# Verification decisions and checkpoint evidence

Evidence recorded October 2, 2026. This reference groups decisions by the behavior they protect, then gives a chronological checkpoint table. Plans and "pending" statements below are historical, not current acceptance. See [verification status](README.md) for the latest scoped summary.

## Runtime checkpoints, runs94-107

| Checkpoint | Result and evidence scope |
|---|---|
| Run 94 | [Run94 (abdf1e8) passed engine jobs but stopped at Swift compilation: NSMenu.isAttached requires a call, and system accessibility environment keys are read-only.](#run94-result-and-scope) |
| Run 95 | [Run95 passed engine jobs and stopped at Swift compilation because NSMenu.isAttached() is unavailable on current macOS.](#run95-result-and-scope) |
| Run 96 | [Run96 at eb2010d compiled the universal Swift app and passed32 engine tests on Linux/macOS.46 UI results:43 PASS,3 FAIL.](#run96-result-and-scope) |
| Run 97 | [Run97 at50b0235 compiled/passed engine jobs and captured34 images.49PASS/1FAIL of50 written, expected53.](#run97-result-and-scope) |
| Run 98 | [Run98 at12a251f compiled and passed engine jobs.53PASS/2FAIL of55,36 captured states, final completion handshake worked.](#run98-result-and-scope) |
| Run 99 | [Run99 at554321c compiled/passed engine jobs.55PASS/2FAIL of57,36 images, app alive/final handshake complete.](#run99-result-and-scope) |
| Run 100 | [Run100 at33c905f passed engine jobs but failed Swift compilation before UI/artifacts: native editor coordinator init read main-actor AppModel revisions from nonisolated context.](#run100-result-and-scope) |
| Run 101 | [Run101 at68a91a5: Swift app compiled, engine jobs passed;63PASS4FAIL/67contracts,38screens, finish handshake complete.](#run101-result-and-scope) |
| Run 102 | [Run102 at496de6c failed Swift compilation before UI: local focusDiagnostic/resetDiagnostic were nonisolated readers of main-actor state.](#run102-result-and-scope) |
| Run 103 | [Run103 at2051281 compiled and engine stages passed.](#run103-result-and-scope) |
| Run 104 | [Run104 at8b37d6f:63PASS4FAIL/67,38images, artifacts recovered.](#run104-result-and-scope) |
| Run 105 | [Run105 at0baba9a:65PASS2FAIL/67,38images.](#run105-result-and-scope) |
| Run 106 | [Run106 at8694d903:66PASS2FAIL/68,39images.](#run106-result-and-scope) |
| Run107 | [Reported 67 PASS / 13 FAIL of 80; forward Tab exact field/editor independently accepted.](#run107-result-and-scope) |

## Detailed checkpoint results

### Run94 result and scope

Run94 (abdf1e8) passed engine jobs but stopped at Swift compilation: NSMenu.isAttached requires a call, and system accessibility environment keys are read-only. The repair uses optional, writable SPZ_DEMO override keys; nil inherits live OS values in normal operation. No UI screenshots or race runtime results came from run94. The repaired consolidated checkpoint is still pending; E1 and E2 stay open.

### Run95 result and scope

Run95 passed engine jobs and stopped at Swift compilation because NSMenu.isAttached() is unavailable on current macOS. Removed the unavailable API; parent highlighted identity is a tracking diagnostic only, never submenu visibility proof. Actual submenu pixels remain mandatory and unverified. No runtime evidence/artifacts came from95. Added two controlled real-session overlapping scan regressions: old progress and old completion are held while a newer scan completes, then released; identity, revisions, bytes/items, elapsed/result time, error and scanning state must remain current. Pending macOS execution. Next combined scope is46 assertions/30 images and32 engine tests, no exhaustive testing or readiness claim.

### Run96 result and scope

Run96 at eb2010d compiled the universal Swift app and passed32 engine tests on Linux/macOS.46 UI results:43 PASS,3 FAIL. All6 UUID publication barriers passed, including overlapping real scan progress/completion.30 images exist. Exact large-folder exclusion/depth12 projection and actual399/401 deep/empty/10,001 count checks passed; inspected images show the deep rows and aligned counts. Five E2 mode/labels/keyboard/restoration checks passed with injected preferences; source and injected modes do not prove real OS notifications or VoiceOver.

### Run97 result and scope

Run97 at50b0235 compiled/passed engine jobs and captured34 images.49PASS/1FAIL of50 written, expected53. Actual choice submenu pixels23-25 now show date/max/sort options; tracking diagnostics pass. Count selected/unselected light/dark/injected Increase Contrast contracts and pixels31-34 pass narrow scope, independent review pending. Sampled repeated core count-ink contrast versus adjacent flat background: selected light5.430/dark6.235, normal light3.949/dark5.925, increased light14.353/dark12.274; not a formal compliance/every-antialiasing-edge guarantee.

### Run98 result and scope

Run98 at12a251f compiled and passed engine jobs.53PASS/2FAIL of55,36 captured states, final completion handshake worked. Root960x600 and contentLayoutRect960x600 passed while contentView960x652 includes unified chrome; actual26 fit pixels await independent review. Primary count31-34 and inactive35 branches pass narrow color/identity contracts. Visible reload36 and exact Tab destination fail.36 shows gray inactive selection after reactivation, so do not claim active reload color coverage or blame product focus without responder/key-window evidence. Escape and single-selection final checks pass. Add explicit responder/window/node/row diagnostic details before next coordinated slice, not an immediate harness-only rerun. E1 accepted across96/97 and new menu regression checks pass, not full E2/release approval. Artifact https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37064592633/artifacts/11252766224 .

### Run99 result and scope

Run99 at554321c compiled/passed engine jobs.55PASS/2FAIL of57,36 images, app alive/final handshake complete. Both zero-byte fixture contracts pass: rootcount1/rects0 data, matching warning/removal policy confirms once through mock while nonmatch stays blocked. This is not SwiftUI zero-area-state pixel proof. Treemap revision/current gates compile, not forced-interleaving race proof.

### Run100 result and scope

Run100 at33c905f passed engine jobs but failed Swift compilation before UI/artifacts: native editor coordinator init read main-actor AppModel revisions from nonisolated context. Coordinator is now explicitly MainActor in source; semantics unchanged, repaired compilation/runtime still pending. No new focus/editing/zero-area pixels from100. All prior open scope retained. Public unauthenticated GitHub API rate limit reached on shared IP; stop those requests until reset, use bounded live UI reads, never pretend absence of API results means task completed/unavailable. No immediate harness-only rerun or readiness.

### Run101 result and scope

Run101 at68a91a5: Swift app compiled, engine jobs passed;63PASS4FAIL/67contracts,38screens, finish handshake complete. Active reload/Tab/ShiftTab still fail with key=false; exact cause unknown and not exonerated. Same-value marked reset conjunction fails without sufficient predicate diagnostics; ordinary marked update and manual editing simulations pass, not actual IME or automatic notification proof. Actual37/38 independently accepted narrow zero-area/no-match presentation, not full-fit/E2/treemap-race proof. Footer wrap and singular item/file defect motivate fixed-height single-line path-truncating footer with full-path tooltip. Next source slice adds window/activation/key-chain and per-predicate reset diagnostics with bounded consumed-reset wait; strict expectations unchanged. No follow-on CI or release until independent source recheck and checkpoint coordination.

### Run102 result and scope

Run102 at496de6c failed Swift compilation before UI: local focusDiagnostic/resetDiagnostic were nonisolated readers of main-actor state. Both engine test stages passed. Explicit @MainActor diagnostic-function repair preserves strict67/38; requires source recheck and coordinated compilation checkpoint. No new footer, focus, reset or empty-state pixels/diagnostics; Run101 failures/unknown causes remain. No release/readiness.

### Run103 result and scope

Run103 at2051281 compiled and engine stages passed. Recovered exact assertions from raw job log:63PASS4FAIL/67; active reload/Tab/ShiftTab still failed. Same-value clear consumed reset and left editor/field/model empty/unmarked, but equalBeforeClear=false leaves strict fixture contract failed/unexercised. CreateArtifact timed out after five internal attempts; live source reports0artifacts. Late diagnostic notice truncated; footer pixels/prestate focus/reset evidence unavailable. Evidence-retention slice prints compact critical diagnostics as ordinary job output before upload and always runs final UI failure gate, including missing/skipped assertion outcome; checks remain67/38. No product focus/reset repair or readiness inferred, no automatic identical retry.

### Run104 result and scope

Run104 at8b37d6f:63PASS4FAIL/67,38images, artifacts recovered. Focus diagnostics show direct resignKey left NSApp.keyWindow pointing to product window while isKey=false; Apple says never call resignKey directly. Actual loop table.nextKeyView is NSScroller/nextValid wrapper instead of name field; exact overwrite source unknown. Pending product repair reconnects boundary in native Tab/backtab handling, not demo; fixture uses real disposable key window and captured product restore. Same-value reset consumed and empty/unmarked but original postmarked field=model-empty premise false (marked editor/field="再", model=""); old exact equality contract unexercised. Revised fixture requires all empty before marking, empty model plus marked editor/field divergence afterward.67checks/38images retained; existing reverse check also exercises actual downstream-forward/table-backward routes to reject two-control cycles. Actual10426/37/38footer single baseline and correct singular labels, scoped fixture fit only. No runtime claim for new source, no release/readiness.

### Run105 result and scope

Run105 at0baba9a:65PASS2FAIL/67,38images. Actual alternatekeywindow/productrestore and active reload/countpixels pass scoped; corrected manual empty-model/marked-editorfield reset and ordinary marked preservation pass, not actual IME or old impossible equality premise. ExactTab/strengthenedShiftTab still fail with genuine prerequisites; product keyDown routing/reconnect unproven. Next slice adds Perf-only route entry/modifier/raw+valid chain/postselect logs (valid-chain reads may perturb recalculation, not cause proof), no routing change. Substantive full/compact footer preserves partial/unreadable/accounting/filter cues and full help/AX details with shared singular helpers. New explicit simulated simultaneous warning state39 retains37/38; canonical68checks39images. Compact fixed-size summary can still overflow if neither variant fits; actual minimum-width39pixels required, no universal fit/readiness. Simulated warning presentation is not permission/cancel accounting.

### Run106 result and scope

Run106 at8694d903:66PASS2FAIL/68,39images. Native keyDown runs; raw/valid namedfield boundary remains before/after reconnect, but selectNextKeyView changes chain/destination to wrapper during call. Instrumented trace, not exact cause proof.39simultaneous warnings/fullvariant fit at960x600; compact unexercised and warnings simulated, not permission/cancel accounting.37/38 semantics retained. Next product changes to explicit active/key/same-window visible/enabled native boundary makeFirstResponder, source/currenteditor validation, refusal/restore outcomes; ordinary other routes native. Old keygraph contract not repaired, functional injectedTab/ShiftTab still required. Planned80checks39states adds direct injectedbacktab and11isolated helper/defensive API simulations; real modifiedshortcut/fallback execution unproven. Missingtable emits canonical new failures; per-case source/target setup checked, disposable windows restored with defer. No readiness/fullE2/IME/OSAX/forcedraceclaim. Checkpoint results belong in this ledger, not in the product overview.

### Run107 result and scope

Reported 67 PASS / 13 FAIL of 80; forward Tab exact field/editor independently accepted. Two reverse checks and eleven helper checks failed; no reverse/helper acceptance. Fixture diagnostic source `72e178a` is separate from the product baseline `e2cd228`; [follow-up108](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37088229962) pending. [Observed run](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37086620447).

## Failure details accompanying checkpoints

### Run96: submenu pixels absent

Remaining failures are submenu tracking23/24/25 (highlighted=nil). Actual screenshots show only root filter/sort menus, no choice submenus. E1 remains open and no release-readiness claim is made. Independent artifact review is pending. Do not weaken this gap into root-menu/source/effect coverage; no immediate harness-only full rerun. Artifact: https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37057037990/artifacts/11249012822 . This is diagnostic CI evidence, not a delivered release.

### Run97: minimum height and teardown gap

Minimum-height assertion failed: measured contentView960x652, not960x600. Need authoritative layout-content/root measurement, not width-only acceptance. Final Tab/Escape/single-selection assertions did not reach file because runner killed app immediately after capturing34. App alive at end/no crash artifact. Explicit demo-finished handshake repaired in source, unexecuted; final focus checks remain unverified. No immediate harness-only rerun/readiness. Artifact https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37060726827/artifacts/11250503094 .

### Run99: inactive key-window and absent Tab destination

Same two focus gates fail with useful diagnostics: visible reload key=false despite makeKeyAndOrderFront, preserved node1/row0, inactive labelColor. Tab key=false, intended nextValidKeyView=nil, responder becomes SwiftUIOutlineListView and selection remains1. Active restoration precondition and exact intended Tab destination are absent; cause/product defect not established. Expectations remain unchanged. Full36 shows neutral readable inactive selection; date submenu23 remains visible. No immediate harness-only rerun, E2/release not approved. Artifact https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37067135227/artifacts/11253697318 .

## Outline, zero-byte membership and root-local empty states

Unicode-lowercase name and extension matching now agrees with name sorting (no Unicode normalization or full case folding promised). Filtered Largest and Kinds keep zero-byte matches by item count; zero-area treemap regions remain absent by design. Engine coverage adds empty/missing/file roots, unusual names, sparse and zero-byte hardlinks, inverted/extreme filters, depth and exact parent/name identity, inclusive dates, mixed-case extensions, invalid FFI buffers/IDs and independent reproducers.32 engine tests pass locally on Linux; native macOS execution is pending.

Next substantive consistency/safety slice (uncompiled/unexecuted): Swift now uses existing spz_filter_count for filter membership. Previously SelectionBar and removal guard treated zero allocated bytes as outside-filter, wrongly warning/blocking matching zero-byte files even though outline/Largest kept them. New disposable zero-byte fixture checks count1/bytes0, hidden nonmatch refusal, matching confirmation and one mocked Trash call; no user files are touched. Pending56-contract/36-image checkpoint, not permission to remove anything without confirmation.

Treemap async publication now checks cancellation, generation and current tree/root/filter/size inside main actor, invalidates on disappear, clears hover on relayout and rejects interactions/readouts from stale root/filter/size or foreign-tree layout. Previous picture may stay visible while new same-tree layout computes, but cannot select from stale coordinates. This is source hardening, not reproduced runtime race or deterministic treemap barrier proof yet. Existing32 engine tests pass locally, no engine behavior changed. Focus diagnostics include selected cell backgroundStyle; failed Tab/active reload expectations unchanged pending real responder diagnosis. No CI run yet, E2/release remains open.

Independent source review accepts count-based zero-byte membership semantics with pending/protected guards unchanged, mocked Swift execution pending. Treemap repair also stamps model.revision, rejecting in-place forget mutations before relayout. No-matches overlay uses only current layout and a settled filter, so an old empty layout cannot claim the new filter has no matches. Still source-only treemap acceptance, not one of six previously proven cache interleavings. Focus failure causes remain diagnostic/open. No readiness.

Treemap zero-area semantics repair: settled current layout with no rects shows No matches only when activeFilter.count(displayedRoot)==0. Matching zero-byte-only items instead show a truthful no drawable allocated space state, directing to outline/Largest. Root-local count, never global filter count, owns this distinction. Disposable zero-byte fixture asserts root count1 with zero rects and excluded-file count0.57 planned contracts; Swift runtime/pixels pending, no CI or readiness claim.

Independent38b271d source accepts root-local zero-area distinction and retained guards. The fixture assertion is named zero-match-root-count-and-layout-data-contract: it proves count/rect data, not an instantiated SwiftUI zero-area message or pixels. Combined checkpoint includes mocked zero-byte removal regression and unchanged two failing focus/reload contracts with more diagnosis.57 results/36 states, no source-only E2 or treemap race proof/readiness.

Disposable SwiftUI zero-area and no-match fixture states37/38 now included: count/size setup assertions are distinct from actual pixels, which must show truthful messages.60 results38 states planned; no CI until independent source review/coordination. Previous E1/six specific cache barriers accepted, treemap forced race/actualOS/olderOS/VoiceOver/full E2/readiness gaps retained.

## Publication identity and barrier causality

Async filter, outline and derived publication checks cancellation, generation and tree identity inside the main actor. Scan progress/completion checks scan generation and session identity. CI adds token-specific barriers that hold old computed work across newer-filter completion, tree clearing and a different arena with reused node IDs, then verify completion did not replace current state. This is uncompiled and unexecuted until the macOS checkpoint, not race signoff.

Independent source review caught a progress-barrier false-positive: multiple callbacks share one scan generation. Every publication now carries a unique UUID; after-hook completion must identify the parked invocation, and each regression checks that it is incomplete before release. Replacement-root expectation comes from the previously scanned replacement Tree.path(0), with non-nil checks, not independent path normalization. Source review/runtime remains pending;46 assertion scope unchanged.

## Submenu pixels, layout measurements and capture completion

The consolidated checkpoint expects44 assertions and30 captured states, including actual submenu attachment, exact large-folder exclusion and depth12 projection, light/dark minimum960x600, injected live Reduce Transparency/Motion toggles, keyboard selection and restoration. Pixels still decide: prior E1 submenu/deep images failed. Injected environments are not OS preference or VoiceOver proof. No E1/E2 completion or release-readiness claim before independent review. Permission-denied/mount/volume races, leak accounting, real VoiceOver, accent normalization and real hardware performance remain open; no exhaustive-edge claim.

Remaining failures are submenu tracking23/24/25 (highlighted=nil). Actual screenshots show only root filter/sort menus, no choice submenus. E1 remains open and no release-readiness claim is made. Independent artifact review is pending. Do not weaken this gap into root-menu/source/effect coverage; no immediate harness-only full rerun. Artifact: https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37057037990/artifacts/11249012822 . This is diagnostic CI evidence, not a delivered release.

The failed submenu action dispatch is replaced in the pending harness by native tracked-menu down/right keyboard events; parent highlight remains diagnostic only. Actual choice submenu pixels are still required. Planned consolidated scope53 assertions/34 images; no new checkpoint until independent source review and parent coordination.

Minimum-height assertion failed: measured contentView960x652, not960x600. Need authoritative layout-content/root measurement, not width-only acceptance. Final Tab/Escape/single-selection assertions did not reach file because runner killed app immediately after capturing34. App alive at end/no crash artifact. Explicit demo-finished handshake repaired in source, unexecuted; final focus checks remain unverified. No immediate harness-only rerun/readiness. Artifact https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37060726827/artifacts/11250503094 .

Independent cumulative source review accepts fail-closed final handshake and minimum root/layout logging, runtime still decides. Inactive/reactivated selection checks now preserve model-node/table-row identity before/after focus changes. State36 is visible reload/reselect color evidence, not offscreen recycled-cell reuse; named accordingly.55 assertions/36 states unchanged, pending coordinated checkpoint. Offscreen reuse, actual OS and full E2 signoff not claimed.

## Count colors, selection restoration and scoped contrast

Next substantive E2 slice, committed but uncompiled/unverified: folder counts use selected control text on emphasized rows, secondary text normally and primary label with Increase Contrast. Native display-options notification and effective-appearance change refresh the cell colors. Full path tooltips preserve deep-name identity. CI-only contrast override is ignored in normal operation. Plan selected/unselected light/dark/increased-contrast images31-34; log alpha-composited semantic-color contrast against a background proxy, not a rendered WCAG verdict. Minimum check now verifies960x600, with narrow Tab/focus, Escape/no-effects and single-selection contracts. These do not claim a complete AX tree, actual OS preference notifications, motion behavior, older-macOS fallback or VoiceOver.

Independent source review accepts count color refresh/reuse, not runtime. Focused harness corrections: Tab must reach the next visible key-view identity (or its field editor), Escape starts without pending removal/message and preserves both, submenu navigation normalizes with Home then counts only enabled/nonhidden selectable items. Actual focus/menu pixels and runtime remain pending.53-check/34-image scope unchanged; no real OS, motion, AX-tree or older-OS signoff.

Independent scoped E1 acceptance is achieved across checkpoints through run97 submenu choice pixels; this is not whole-run97/E2/release approval. E2 selected-count readability and injected branch layout accepted visually; raw contrast audit now preserves originals, fixed crops/background coordinates, full qualifying-color frequencies and executable method for independent reproduction, not formal compliance.

Next product refinement, pending source review/runtime: unselected count uses primary labelColor universally; selected count retains selected control text. Size/path hierarchy remains separate. Inactive selection and row reload/reuse color contracts/screens35-36 planned. Minimum check measures actual SwiftUI root and contentLayoutRect against960x600 while logging contentView/chrome separately; raw960x652 does not waive600 layout fit. Explicit demo-finished handshake waits for final focus assertions before teardown. Planned55 assertions/36 images; no CI or readiness until coordinated checkpoint. Actual OS, motion, olderOS and VoiceOver gaps remain.

## Native field editor and external-reset policy

Next substantive native focus slice, uncompiled/unverified: name filter is an NSTextField bridge with same model debounce, accessible label and native field editor. Weak model references explicitly connect outline nextKeyView to named visible filter across hosting boundary. Normal Tab then ShiftTab must reach exact field/editor and outline identities with selection unchanged. CI requests NSApp.activate(), waits up to5s and requires actual appactive/windowkey/successful makeFirstResponder(table) before active reload/focus checks. Activation request is not guarantee; missing setup stays failure/blocker, never PASS. Previous key=false/nil intended destination did not establish product cause/exoneration.

Independent focus source review requested attachment/parity corrections before checkpoint. Product field/table now reconnect on viewDidMoveToWindow, preserving any forward chain beyond the field. Demo observes established next/previous valid identities, never calls product bridge repair. ShiftTab requires successful forward field start; reload gate rechecks actual active/key/table responder at assertion time. Native editor model sync preserves cursor selection and avoids overwriting marked text. Four narrow editor API regressions plan typing, external text/cursor, clear-all while editing and marked-text commit simulation; simulation is not actual IME/keyboard-source proof.64 planned contracts38 states, uncompiled/unexecuted and no CI yet. Full pixels37/38, activation/focus runtime, actual OS/olderOS/VoiceOver and treemap race gaps retained.

Explicit editor UX policy: an external clear/change cancels unfinished marked composition before replacing filter text; newer external model intent wins over a later composition notification. New regression changes model while hasMarkedText=true, checks marked state cancelled/editor-field-model cleared and a simulated delayed delegate cannot resurrect stale filter. Native editing tests explicitly invoke delegate, so they do not prove automatic notifications or actual IME behavior.65 scoped contracts38 images planned. Independent lifecycle/focus source scope is suitable for checkpoint; no editing parity/full E2 claim.

Independent reset robustness correction: capture external target before unmarkText; suppress synchronous coordinator feedback during programmatic cancellation/replacement and install captured target in editor/field. Check editor string/marked divergence even when field equals model; regression includes already-empty model with marked editor then clear. Current-field manual delegate simulation cannot prove arbitrary delayed IME insertion behavior; no all-delayed-commit guarantee.66 scoped contracts38 states, uncompiled/unexecuted. Source recheck before checkpoint, actual IME/automatic notifications still open.

Independent source blocker found marked-state-only overwrite cancelled ordinary composition on any redraw. Repair separates editor-origin updates from external text changes and explicit clear/reset revisions. Only actual external intent cancels composition; marked ordinary updates preserve editor text. Captured target/programmatic delegate suppression retained. Equal-value clear bumps reset revision; regression asserts field==model==empty before marked reset, plus ordinary marked/unrelated update preservation.67 contracts38 states pending source recheck, noCI/runtime/IME/E2 claim.

Independent origin/revision source blocker closed; composition fixture now waits explicit coordinator-consumed reset revision before creating marked text. Ordinary update uses a refresh token read in updateNSView and checks actual update count advanced with unchanged external/reset revisions, marked text preserved; not sleep/contrast redraw inference. Evidence counters are observation-ignored to avoid redraw feedback. Equal-before-clear assertion retained.67 contracts38 states still pending runtime/source fixture recheck, no automatic notifications/actual IME/full E2 claim.

## Glass and accessibility design before consolidated runtime

- First product slice: filter control surface uses macOS26 system glass with macOS14 material fallback and live Reduce Transparency opaque fallback; Reduce Motion disables implicit content animations. Parent/Stop/selection actions and folder chevrons have explicit accessible labels; decorative outline icons/bars are excluded. Awaiting macOS compile, pixels in accessibility modes and VoiceOver/keyboard evidence. E1 submenu/depth evidence remains open and will share E2 consolidated verification, not another immediate harness-only run.

## Earlier E1 failures and evidence retention

- Run37040037876 failed capture1: app-launched screencapture did not create images. Replaced with CI-only state/capture acknowledgement: runner captures using its existing permission, then acknowledges before app state advances. No permission bypass. New consolidated check pending.

- Run37043128105 at c892613 passed all30 checks and captured22 images. Pixel review confirms399/401pt empty/five-digit counts and real date/sort/reset effects. Depth12 evidence is not yet accepted: /tmp vs /private/tmp path mismatch left the large folder expanded. Canonical-path fixture exclusion and explicit visible-depth12 check repaired; independent signoff remains pending.

- Run37046851306 failed strengthened depth checks at correct399/401 widths: b-large still expanded; choice-menu images23-25 were blank. Do not accept those pixels. Depth fixture now selects nodes by root-child identity instead of path. Menu visual automation remains unresolved; no new checkpoint before that review decision.
