# AGENTS.md

Working agreement for anyone (human or agent) changing Spacelyzer Native. Read it before the first edit.

## What this is
A native macOS disk analyzer. SwiftUI draws the interface. A Rust engine owns every computation over the dataset:
scan, filter, sort, aggregate, layout, hit-testing.

## The bar (from the owner, Karim)
1. Performance is real and perceived. Make the work fast, and never block the UI thread.
2. Every element is polished: every component, slider, panel, button. Things fit, nothing janks.
3. Follow Apple's current Liquid Glass guidance. Rust crates only from reputable sources.
4. Do not claim what has not been measured or looked at.

## Hard rules
**Threading**
- The main thread only renders and handles input. Anything that scales with the dataset (scan, filter, layout,
  outline projection, largest files, kind totals) runs in Rust off the main thread and publishes one result.
- Never compute from the dataset inside a SwiftUI `body`. Cache in `AppModel`, refresh off-main, publish.
- Cancel superseded work (`Task.cancel`) and keep the previous picture on screen until the new one lands.
- Show activity if work takes over 150 ms.
- SwiftUI gets visible rows and rectangles only. No per-node views, no arbitrary cap that hides user data.

**Engine (Rust)**
- Data lives in flat arenas (`Vec`), not node objects. No per-node path strings, no per-node allocation on hot paths.
- Keep Rust timings (engine) separate from copy/UI timings. Report both, never blended.
- Sizes are allocated bytes. Hard links count once. Firmlinks and volume boundaries are handled in the engine.
- New dependency: add a row to `docs/DEPENDENCIES.md` first. `scripts/check-deps.sh` enforces the allowlist.
  Only widely used crates from crates.io with a named maintainer. No git or path dependencies.

**UI polish**
- Prefer standard SwiftUI/AppKit components. They pick up Liquid Glass automatically on the latest SDK.
  Do not paint custom backgrounds on sidebars, toolbars or bars. Do not hard-code control metrics.
- Use glass sparingly on custom elements (`glassEffect`, `.buttonStyle(.glass)`), only for the main functional layer,
  and never stack glass on glass. Gate macOS 26 API with `#available`, keep a good fallback for macOS 14.
- Concentric corner radii, system spacing, system colours (light, dark, increased contrast). Labels truncate in the
  middle with an ellipsis, never wrap or clip mid-glyph.
- Respect Reduce Transparency and Reduce Motion. Everything needs an accessibility label.
- Apple's guidance: https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass

**Destructive actions**
- Move to Trash only, always after a confirmation that shows the full path. Never permanent delete.
- Removal is unavailable when the selection is hidden by the filter or while a filter result is pending.
- Tests that trash anything use a disposable fixture under `/tmp/spz-trash-fixture`, never real user files.

## Working method
- One concern per commit, in dependency order. Validate a slice before building on it. Do not bundle architecture,
  filters, visual fixes and packaging.
- Fix the cause, not the symptom. If a revert or a change did not land, check `git log` before saying it did.
- Write the failing check first when you can (Rust test, or a UI assertion in the CI demo run).
- Read screenshots yourself. A visual change is not done until you have looked at the pixels at the sizes that matter.
- Public docs and release notes only say what was measured. Keep the "not verified" list honest.

## How to verify
- Engine: `cargo test --release -p spacelyzer-engine`. CLI: `./target/release/spz scan|verify|bench|filterbench <path>`.
- App (macOS): `./scripts/build-engine.sh && swift build -c release`.
- CI (`.github/workflows/ci.yml`) builds, tests, signs (self-signed), runs the scripted demo, takes screenshots,
  and runs the UI assertions. The demo run (`SPZ_DEMO=1`) posts real events to the app window and logs
  `Perf` timings and main-thread stalls. `ui-assertions.txt` is published with each release and fails the build on any FAIL.
- CI output only goes through check-run annotations (public). Annotations are capped, so durable evidence goes in
  files (`ui-assertions.txt`) and release assets.

## Signing and secrets
Self-signed with the project certificate. No Apple Developer ID, no notarization, no paid CI. Secrets live in the
vault and CI secrets only. Never in the repo, artifacts, logs or messages. Gatekeeper will block the first launch:
the supported path is System Settings > Privacy & Security > Open Anyway. Do not suggest clearing quarantine
flags or disabling Gatekeeper.

## Layout
- `engine/src`: `scan`, `scan_macos`, `tree`, `layout`, `filter`, `outline`, `category`, `ffi`, `bin/spz`.
- `Sources/CSpacelyzer/include/spacelyzer.h`: the C ABI. Keep it in step with `engine/src/ffi.rs`.
- `Sources/Spacelyzer`: `AppModel` (state), `OutlineView`, `TreemapView`, `ContentView` (split view, toolbar, filter bar,
  status bar), `Engine.swift` (Swift wrappers, `Perf`, `MainStall`), `SpacelyzerApp.swift` (CI demo and `DemoInput`).
- `docs/ROADMAP.md`: what is done, underway and next. Keep it current.

## Stability, memory and resilience (release criteria)

Karim's standing requirement: long-range stability, memory management and resilience. A build is not release-ready until each item below has measured evidence, stated with its limits. Nothing here counts as passed until a CI artifact shows it.

- Node ids are only valid for the tree that produced them. Replacing the tree must clear every id-keyed cache (outline rows and index, expansion, selection, filter result, derived lists, pending removal) in the same main-actor turn, and cancel in-flight tasks that hold old ids. Cross-tree safety must also be bounds-checked at the FFI edge, not only in Swift.
- Repeated rescan soak: scan, swap, rescan many times (including a large tree then a small one, and cancel mid-scan). Record resident memory after each cycle; it must return to a plateau, not climb. Report the numbers and the runner it ran on.
- Long-session soak: scripted browsing, filtering and expansion for a fixed duration with memory sampled at intervals. Report growth per hour as measured, not extrapolated.
- Cancellation and failure: cancelling a scan, scanning an unreadable or vanished folder, and a scan error must leave the previous view usable or a clear empty state, never a crash or stale rows.
- Every Rust allocation behind the FFI has one owner and one free path; trees are freed when the last Swift reference drops. Check with a leak check or allocation counters, and say which.
- Every UI check that exercises these paths must fail CI, and a crash during the demo run must fail the build (the app not running at the end is a failure).

## Workflow: epics, docs and verification
- Work in epics; tasks inside an epic are thin commits in dependency order. CI, tags and releases run per epic (tag `epic-<n>-<name>`), not per task.
- Docs move with the code: any task that changes behaviour, a check, a limit or the roadmap updates README, ROADMAP and AGENTS in the same commit (or the next one in the same epic, never later than the epic tag). An item is ticked only after its check passes.
- Verification is independent: at each epic end, hand a separate verifier only the intended behaviour, scope, commit/artifact references and known limitations. The author's own checks do not replace it.

## E1 verification repair and acceleration evaluation
- Menu-driving timers must run during menu tracking; checks assert actual date/sort/reset effects after settling, never just action lookup.
- Count evidence uses live outline cells near the 400pt threshold, empty folders, five-digit counts and deep rows. Timeouts fail the demo and cannot masquerade as later screenshots.
- Spotlight first-results and dua-inspired streaming remain evaluation only. No preview contributes to authoritative totals or authorizes removal. Preserve MIT notices for any copied upstream code.

- CI captures each demo state before advancing, then collects named images rather than polling a transient latest-step value. Assert all evidence exists; distinguish timeout from app exit in failures.

- Runner-owned screenshots acknowledge a CI-only state hold before progression. This test-only hold must never enter normal app operation. Do not change screen-capture permissions to rescue an in-app test subprocess.

- Fixture path comparisons resolve symlinks (macOS /tmp is /private/tmp). Deep-count evidence checks actual visible rows with depth>=12, never just a broadly named passing assertion.

- E1 final evidence includes actual date/maximum-size/sort choice submenus, not only root menus, in the same consolidated run as deep-row399/401 images.

- E2 control surfaces keep standard native controls; custom glass is one functional layer only. Live Reduce Transparency gets an opaque system-color fallback; Reduce Motion suppresses implicit animation. Verify actual accessibility-mode pixels and keyboard/VoiceOver behavior before calling done.


## Async and edge regression rules

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
