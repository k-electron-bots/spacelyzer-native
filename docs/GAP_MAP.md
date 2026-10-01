# Gap map: Spacelyzer Native vs original k-electron/spacelyzer

Source of truth for the original: its spec (FR-001..FR-071), tasks.md, git history and issues, read at commit 4f12ee6.
"Done" below means present in this repo's code and covered by CI compile/tests only. Nothing here has been run on a real Mac by a person yet.

## What the original says about its own performance (its numbers, its machine)
- SC-001 scan of 500,000 items: budget 60 s, original measured 4.5 s. Scanning was already fast.
- SC-005 hover at 1,000,000 items: measured 1.2 microseconds (spatial index built once per layout).
- SC-009 filter at 1,000,000 items: budget 200 ms, measured 1.55 s, cut to 0.65 s, still missed (open task T133). Cause recorded in the repo: a path string built per node, and a serial walk (0.153 s floor with no filter).
- History shows UI stutter fixes: click rebuilding the window, large folders making clicks feel dropped, resize stutter (children capped per folder, layout coordinator).
Implication: the original's scan is not obviously the bottleneck. The measured miss is filtering at scale, plus UI interaction at large folders. This rebuild's engine speeds up scan and layout but has NO filter yet, so it does not address the one measured miss. No speedup claim until same-folder timings exist.

## Feature status
| Area (FRs) | Status here |
|---|---|
| Pick folder/volume, progress, cancel (001,003,004) | Done (folder/startup/home picker, live count, Stop) |
| Skipped-locations summary (005) | Counted in status bar; no reviewable list UI |
| Hard-link/firmlink/symlink/volume dedupe (006,007) | Done in engine; tested on fixture and agree between backends on CI |
| Rescan, recents (009) | Rescan only by re-choosing; no recents |
| Exclusions persist + UI + stale marking (010-013) | Engine supports exclude list; no UI, no persistence, no stale state |
| Volume accounting, purgeable, snapshots, unaccounted space (014-017) | Missing |
| Full Disk Access guidance and detect-grant (002,018,019) | Text tip only |
| Size units decimal/binary (020,021) | Decimal only, no toggle |
| Outline: name, size, share, item count, sort, keyboard (022-025) | Partial: name, size, share bar; no item count, sort order fixed (size desc), capped to 2000 children |
| Side by side layout (026) | Done |
| Treemap, nesting, colours (3 modes), hover readout, drill, remainder (027-032) | Done in code; completed-scan pixels not yet verified (pending CI screenshot) |
| Cross-view selection sync, reveal ancestors in outline (033-036) | Partial: selection shared; outline does not auto-expand to treemap selection; no drill-reconcile logic |
| Filters: text, category, extension, size, date, combine, counts (037-043) | Missing |
| Category breakdown (044) | Done (Kinds tab); ranking only |
| Quick Look preview, open in default app, item details (045,047,048,050) | Missing (Reveal in Finder only) |
| Removal to Trash with confirm, protected paths, undo last (051-053,055,059) | Partial: single item, confirm, protected list, undo of last. Missing: batch, permanent delete option, history (061), per-item failure handling (056), guard parity with original RemovalGuard (not compared) |
| Duplicates (062-066) | Missing (also unbuilt in the original: open PR #5 / tasks T112-T120) |
| No network (067,068) | No networking code written; not machine-verified |
| 150 ms activity indication, non-blocking UI (069-071) | Scan is async; not measured |
| Accessibility/VoiceOver (T122), icon (PR #3), Developer ID signing (T129) | Missing / self-signed only |

## Known original bugs/gaps found in its own records
- T132: app calls fatalError if its SwiftData store will not open, so a corrupt store makes it unlaunchable. Not applicable here yet (no SwiftData), but history/prefs persistence will need this designed in.
- T133: filter budget miss (above).
- Two real bugs fixed in its history to carry as regression tests: negative device number crash converting to unsigned (84659f4), and firmlinked dirs/separate volumes double counted (31a46c1); also unbounded skipped list making the list impossible to close (82bdaad).
- Original noted APFS clones over-count and snapshots cannot be sized at all; a rebuild must show the same honest caveats.

## Rebuild risks (hypotheses, not measured)
- getattrlistbulk record parsing is only validated by CI equality with the portable backend on a runner, not on varied volumes (APFS firmlinks, network mounts, iCloud placeholders).
- Treemap layout is my own squarified implementation, not a port; visual parity with the original is not verified.
- Layout cap (30,000 rects) and 2,000-row outline cap are choices, not measured limits.

## Suggested order
1. Filters in Rust (text, kind, extension, size, date; count + total) to attack the measured miss; benchmark at 1M items.
2. Exclusions + persistence + stale state; skipped list; volume accounting.
3. Outline parity (counts, sort, reveal ancestors), details/Quick Look, batch removal and history, permanent delete.
4. Duplicates; accessibility; icon.
5. Same-folder timing of both apps on a real Mac.
