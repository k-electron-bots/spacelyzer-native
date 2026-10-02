# Roadmap

Priorities, in order: safety, real and perceived performance, pixel polish, then new features.
"Verified" means checked by the CI demo run (real events posted to the app window on a shared GitHub Mac, screenshots
read by a person). Nothing here has been verified on a personal Mac yet.

## Done and verified on CI
- Rust engine: parallel scan, flat tree, hard-link and firmlink handling, filter, outline projection, treemap layout and hit-testing.
- Windowed outline (no row cap), keyboard navigation, one filter for every view, "No matches" states.
- Selection safety: Move to Trash is unavailable when the selection is hidden by the filter or a filter result is pending.

## Underway
1. Verify real Trash round trip on a disposable fixture (in CI), and main-thread stall measurements for hover, typing and expand-all.
2. Largest and Kinds lists moved off the main thread and cached (committed, awaiting CI proof).

## Next
1. Pixel polish against Apple's Liquid Glass guidance: system styling for the status bar, selection bar and filter field,
   glass button styles, concentric corners, hover states, Reduce Transparency and Reduce Motion, minimum window size.
2. Accessibility: labels for every row and control, VoiceOver pass.
3. Outline: reveal collapsed ancestors on selection, sort options, item counts.
4. Filters: file extension, maximum size and date range in the UI.
5. Volume view: used, free and purgeable space, snapshots, unaccounted space.
6. Details and Quick Look for the selected item; batch removal with history.
7. Exclusions with persistence; a reviewable list of unreadable locations; Full Disk Access detection.
8. Duplicate finder.
9. App icon, size-unit toggle (decimal or binary).

## Not verified
Real-Mac behaviour, other window sizes, multiple volumes, APFS clones, purgeable space, VoiceOver.
