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

Reported 67 PASS / 13 FAIL of 80; forward Tab exact field/editor independently accepted. Two reverse checks and eleven helper checks failed; no reverse/helper acceptance. Fixture diagnostic source `72e178a` is separate from the product baseline `e2cd228`; follow-up108 also failed, as recorded below. [Observed run](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37086620447).

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

## Run108: native event identity and blocked helper setup

October 2, 2026, fixture source `72e178a`: 67 PASS / 13 FAIL of 80, 39 captured states. Forward Tab still reached the exact name field/editor without changing selection. Shift-Tab arrived with keycode48, Shift, characters0x19 and charactersIgnoringModifiers0x09; the correct field/editor delegate received `insertTab:`, so reverse handling was not exercised. Apple documents that charactersIgnoringModifiers preserves Shift; faithful event construction remains a fixture prerequisite, not a reason to certify or bypass the product handler.

The helper window was key, active and visible, but its bare table reported acceptsFirstResponder=false and the actual first responder was BoundaryWindow. makeFirstResponder returned true, demonstrating why its Boolean alone is not acquisition proof. All eleven helper results are blocked setup, not guard execution or eleven product bugs. A realistic native table and exact responder identity must be established before repeating those cases. No acceptance override is a substitute for that proof.

[Run108](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37088229962) · [Artifact](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37088229962/artifacts/11260769990) · [Apple event contract](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingKeyEvents/HandlingKeyEvents.html). Linux/engine and build steps completed; the strict UI gate failed. No release, native-graph repair, modified-shortcut fallback, actual IME or real-hardware claim follows.

## Run109: faithful BackTab and native source acquisition

October 2, 2026, fixture source `ba3de86`: compiled, 77 PASS / 3 FAIL of 80, 39 captured states. Shift-Tab with both character fields0x19 reached `insertBacktab:` in the exact name-field/editor delegate. Forward and reverse named focus boundaries passed with preserved outline selection and unchanged product routing. The realistic one-row/one-column scroll-hosted table, with strongly owned datasource, accepted focus and was the actual first responder. Nine native helper/defensive-simulation checks passed, including exact decoy landing, restoration and the simulated restore-refusal flag. This scope is independently accepted; actual modified-shortcut/native-fallback execution remains unproved.

Three checks still failed. Downstream forward Tab found no nextValidKeyView candidate, while the actual responder was a SwiftUI field editor; the expected semantic extension-control identity was not yet asserted. Hiding the source left a field editor as responder, making the fixture's post-hide source-equality premise suspect. The native refusing target produced an unexpected landing that the product restored exactly, but the fixture expected only `.unavailable`; actual target callback, API outcome and helper result still need explicit tracing. These are not retroactive passes. Apple documents that makeFirstResponder may return true with the window as first responder when the target refuses.

[Run109](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37089357517) · [Artifact](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37089357517/artifacts/11261448463) · [Apple focus API contract](https://developer.apple.com/documentation/appkit/nswindow/makefirstresponder(_:)). The strict UI gate failed. No release, old graph repair, whole-keyboard, actual IME, automatic-notification or real-hardware claim follows.

## Run110: revised semantic and native refusal contracts

October 2, 2026, source `d21aab7`: both jobs succeeded, Swift compiled, 80 distinct PASS / 0 FAIL assertions and 39 captured states. Independent review accepted the bounded behavior/timing evidence and all fifteen supplied images23-25/28-39. Normal forward Tab reached the unique expected extension field/editor delegate while nativeNext remained nil. Named forward/reverse and upstream consistency passed, not the old native-graph contract. Hiding the source relocated focus before the helper; the helper refused and preserved that exact captured post-hide responder. Hidden/not-current predicate overlap remains a limit.

The native refusing target's becomeFirstResponder callback ran once and returned false. The API returned true with BoundaryWindow as responder, then restoration returned true with the exact source table. The helper returned `.restoredUnexpectedLanding` and did not consume the command. Defensive false-with-decoy and restore-failure cases remain simulations, not normal AppKit behavior or actual caller-fallback proof. The revised contracts are prospective; run109's three historical failures remain unchanged.

Ungated shared-runner performance: first-click latency2,096.7 ms/stall2,093.2 ms, later click37.6 ms, typing/filter-arrow stall316.2 ms; 40-arrow p50/p95/max35.7/74.6/117.3 ms; hover0.7 ms. The broad existing sample window does not isolate the first-click cause. Green assertions do not establish smoothness, a performance pass or a regression.

[Run110](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37092313793) · [Artifact](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37092313793/artifacts/11263786545). Release publication was skipped. Compact footer, actual modified-key/native-fallback execution, actual IME, VoiceOver/OS AX, forced treemap interleavings, full E2 and real hardware remain open.

## Run111: natural compact footer and incomplete causal alignment

October 3, 2026, source `df05490`: both jobs succeeded, Swift/UI steps passed, 81 distinct PASS / 0 FAIL, 40 captured states, release skipped. Independent review inspected image40 and accepted the new compact presentation on a separate700pt CI surface. Production ViewThatFits chose Partial/filter1file/1,234,567unreadable labels naturally and kept all readable without overlap. The main app minimum was not changed. Warnings remain presentation simulations; actual help/AX and real permission/cancel accounting are not proved. The qualified FDA welcome copy is source-reviewed, not visually exercised here.

One cold sampler ran at5ms for8s against process17506/version0.1.111, raw header03:55:06.825UTC, exit0. The03:58:06UTC completion entry records the later workflow wait, not actual sampling end. Buffered stages show roughly202ms between event-post and tablemouseDown, about2.65ms in native mouseDown and about0.2ms callback/model assignment. Wall-clock/uptime overlap is unbridged, and the aggregate sample has no per-stack chronology; no frame can be assigned to the pre-table gap or the earlier2s stall. The fixed12s summary caption is wrong for this8s report and is not interval evidence.

Shared-runner/profiler-perturbed measurements: cold260.9ms/stall252.8ms, later42.3ms; 40-arrow p50/p95/max18.6/187.4/787.6ms and stall789.6ms; typing/filter-arrow stall162.1ms; hover0.6ms. Mixed latency does not establish an overall performance improvement or regression. Existing synchronous logs also perturb the path.

[Run111](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37094174463) · [Artifact](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37094174463/artifacts/11264190402). No native-graph, actual shortcut/fallback, IME/AX/VoiceOver, forced treemap-interleaving, full E2 or release acceptance.

## Run112: clock bridge reveals missing cold-input coverage

October3, source `913c339`: Swift/Linux passed, strict UI gate failed,81PASS/1FAIL of82,40states. Only the new footer native full-label retrieval failed: the actual NSHostingView root had empty label/help and no children,1node,truncatedfalse. This is a limitation of the tested in-process retrieval path, not proof of external AX absence. Pixel40 compact simultaneous-warning presentation remained readable.

Clock PID12802 matches report/version0.1.112 and command8s5ms. Paired trace wall04:39:31.035530/.035531UTC precedes rawheader04:39:31.319UTC by283.47ms; selection wait115.5ms/nativecallback95.1ms finished before that header. Launch acknowledgement does not establish cold-input sampling coverage. Subprocess end04:39:40exit0 includes report/symbol processing; workflow wait04:42:34 is later. Cold115.5/stall111.1ms, warm34.5; arrowp50/p95/max34.2/296.8/553.5ms,stall548.1,typing261.8,hover0.5. Mixed ungated results, no overall win or causal stack assignment.

[Run112](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37096739621) · [Artifact](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37096739621/artifacts/11264119652). Release skipped.

## Run113: actual mounted resize and still-failing native footer retrieval

October3, source `63cc6e9`: Swift/Linux passed, strict UI gate failed,83PASS/1FAIL of84,42states. The footer full-label check still failed: root-window title plus one empty ax-child,2uniqueobjects,truncatedfalse. Discovery included native AX children, view subviews and window content; first-discovery edge logs preserve provenance. This does not prove external client reachability or absence; actual help/VoiceOver/tooltip remains open.

Two actual mounted TreemapView checks passed. Old UUIDD8DFD154 generation2/request520x300 was held after real Rust layout. New UUIDF0E50A98 generation3/request680x360 published layout0xb0e422240/tree0xb0bc1b660. The old main-actor callback then ran and rejected, preserving new exact identity,size and Rust center-hit/chosen-node correspondence. Actual pixels41/42 were inspected: large.txt/small.bin fill the mounted680x360 surface with readable labels, unchanged after old release. Independent bounded resize acceptance confirmed. One resize interleaving only, not gesture dispatch, filter/tree/unmount or universal race proof.

Explicit1s async profiler-start settling changed idle/arm conditions, without input/product prewarming. PID21499/version0.1.113/command8s5ms match; rawheader05:11:36.179UTC precedes tracewall05:11:37.072619/.072620 by893.619ms. Actual subprocessend05:11:45exit0 includes processing, workflow wait05:14:41 is not end. Temporal bracket aligns the input with this requested sample arm, not per-stack chronology. Diagnostic selectionwait821.2/stall821.9ms; nativecallback120.845ms, outlineupdate470.492ms. Arrowp50/p95/max18.9/140.9/429.2ms/stall137,typing111.9,warm24.5,hover1.3. No cold comparison, overall improvement or causal frame claim.

[Run113](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37098640048) · [Artifact](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37098640048/artifacts/11265437495). Release skipped; real hardware/full E2 and wider accessibility/interaction gates remain open.

## Run114: explicit passive summary semantics, retrieval still failing

October3, source `6c3bc6d`: Swift/Linux passed, strict UI gate failed,83PASS/1FAIL of84,42states,release skipped. Adding accessibilityElement(children:.combine) to the passive ViewThatFits summary retained fullDetails and left path/progress/controls separate. It did not repair tested native full-label retrieval: root-window title plus one empty ax-child,2nodes,truncatedfalse. No external client absence, VoiceOver or help/tooltip claim follows.

Actual pixels39/40 were inspected: full and700pt compact simultaneous simulated partial/filter1file/unreadable labels remain readable without overlap. Pixels41/42 show the mounted680x360 two-file treemap unchanged after held old resize release. OldUUID52379030 generation2/request520x300 rejected after newECD8BEEC generation3/request680x360; exactlayout0xcafa563c0/tree0xcb3d81880,size and Rust center-hit correspondence preserved. This repeats the narrow independently accepted run113 resize case, not new gesture/filter/tree/unmount coverage.

Diagnostic sampled-settled arm PID11681/version0.1.114: rawheader06:08:05.410UTC precedes trace06:08:06.966780/.9667811 by1556.78ms; subprocessend06:08:14exit0 includes processing, later workflowwait06:11:21 is not end. Command requests8s5ms; coarse temporal bracket, not first/last sample or per-stack chronology. Selectionwait1279.1/stall1273.9,warm26.6; arrowp50/p95/max34.0/76.4/768.2ms/stall766.9,typing264.2,hover1.0. Altered idle conditions prevent cold comparison; no overall win.

[Run114](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37101601436) · [Artifact](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37101601436/artifacts/11265798604). Native retrieval gate remains failed; further AX work requires grounded client/retrieval evidence rather than an unchanged rerun.

## Run115: external AX full details reachable; native check still fails

October3, source `f414bec`: Swift/Linux and external client compilation passed; strict UI gate failed,83PASS/1FAIL of84,42states,release skipped. External clientPID20501 had trusted=true and targetedPID11509. The exact700pt footer title/AXWindow role/PID matched. Node6 AXStaticText in that window's subtree returned successful Help and Value with the actual path,ZeroKB1item,partial accounting,Scannedin0.05seconds,FilterZeroKB1file0.3milliseconds,and1,234,567unreadable locations.202nodes,truncatedfalse,process exit0. Irrelevant-attribute errors are retained; they are not absence proof.

Independent review accepted this bounded external API retrieval, not VoiceOver announcements, visible tooltips, OS preference handling, real permission/cancel accounting or combine causality. The separate in-process native accessor check still failed with two nodes,untruncated,even after external acknowledgement. Historical112-114 failures remain failures. Pixel40 was inspected: compact simultaneous simulated warnings stayed readable. Mounted resize checks passed again within the run113 accepted scope.

DiagnosticPID11509/rawheader07:02:23.977UTC precedes trace07:02:24.8409882 by863.9882ms; subprocessend07:02:33exit0 includes processing. Coarse bracket only,not first/last samples or per-stack chronology. Selection185.5/stall205.5,warm38; arrowp50/p95/max18.7/175.3/765.5ms/stall761.3,typing240.1,hover0.9. Alteredidle prevents cold comparison, no performance win.

[Run115](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37104425688) · [Artifact](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37104425688/artifacts/11267976189). Source `3a48eb6` prepares a separate same-node exact UTF8 Help+Value regression (85checks/42states) with mounted expected export, fresh ack, successful client exit and explicit result, while keeping the native failed check. Its runtime checkpoint is pending: GitHub workflow dropdown stayed Loading and no dispatch was submitted.

## Run116: separate formal external regression passes, native gate stays failed

October3, source `2f1ef6e` (reviewed code `3a48eb6` plus docs): Swift/Linux/client compiled; strict UI gate failed,84PASS/1FAIL of85,42states,release skipped. Run dispatched once through a verified existing bot REST route after the browser dropdown stayed Loading. No authentication change or epic release tag.

New separately named external same-node Help+Value exact-details regression passed. Trusted clientPID31581 targetedPID23733; exact700pt AXWindow title/role/PID matched. AXStaticText node6 had successful Help and Value whose UTF8 data exactly matched the mounted StatusBar expected-file bytes. Expected fixture independently checked first-line root path,ZeroKB1item,partial accounting,scan0.03seconds,filterZeroKB1file0.3milliseconds and1,234,567not-readable locations. Freshack=true,statusEXIT_0,resultVERIFIED,202nodes/truncatedfalse. Independent bounded formal-regression acceptance confirmed.

The old in-process native full-label check remained the sole failure with two nodes/truncatedfalse. This is not an external absence claim. Historical112-115 failures stay failures; no VoiceOver announcements, visible tooltips, real warning accounting, OS preference or combine-causality claim. Pixel40 compact simultaneous-warning presentation was inspected and readable; mounted resize checks passed within the existing narrow scope.

DiagnosticPID23733/version116: rawheader08:05:03.198UTC precedes trace08:05:04.1193771/.119378 by921.3771ms; subprocessend08:05:12exit0 includesprocessing. Coarse requested8s5ms bracket,not first/last-sample chronology. Selection614.7/stall609.1,warm53; arrowp50/p95/max15.9/54.7/488ms/stall486.6,typing260.9,hover0.4. Alteredidle arm,no cold comparison or overall performance win.

[Run116](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37108069847) · [Artifact](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/37108069847/artifacts/11269385250). No unchanged rerun or native-gate removal follows from the external pass.
