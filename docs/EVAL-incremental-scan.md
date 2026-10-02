# Evaluation: persisted tree + file-system change tracking (not implemented)

Status: evaluation only. Nothing here exists in the app. Today every scan walks the real file system
(getattrlistbulk, parallel). There is no persisted tree, no FSEvents, no Spotlight use.

## Goal and rule
Make repeat scans of the same location much faster **without ever replacing authoritative accounting
(allocated bytes from the file system) with approximate totals.** A search index (Spotlight) is never the
source of totals.

## Options
1. **Spotlight / NSMetadataQuery.** Rejected for totals: content-search index, excludes private, hidden and
   system areas, can lag or be rebuilding or disabled, and reports logical not allocated sizes. Possible later
   only as an explicitly labelled approximate preview.
2. **Persisted tree + FSEvents.** Candidate. Save the Rust tree (arena, sizes, mtimes) plus per-volume
   `FSEventsCopyUUIDForDevice` and the last event ID. On launch, replay events `sinceWhen` the saved ID and
   rescan only the reported directories, then roll sizes up.
3. **Persisted tree + directory-mtime probing** (no FSEvents). Cheaper to build, but mtime of a directory
   does not change when a file inside a subdirectory grows, so it is unsafe as the only signal.

## What Apple documents (FSEvents Programming Guide and FSEventStreamCreate docs)
- Events persist across reboots; store the last event ID and pass it as `sinceWhen`.
- The stored ID is valid only with the stored volume UUID; a different UUID means the history was purged or
  the volume differs, so discard the saved tree for that volume.
- `kFSEventStreamEventFlagMustScanSubDirs`: events were coalesced; recursively rescan that path.
- `KernelDropped` / `UserDropped`: changes are unknown; do a full scan of the watched directories.
- `EventIdsWrapped`: old IDs are no longer valid.
- Per-volume: mounts inside a tree need their own UUID.
Sources: https://developer.apple.com/documentation/coreservices/1443980-fseventstreamcreate and
https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html

## Accuracy risks and required recovery
- Events say *where* something changed, not the new size, so each reported directory is re-enumerated with
  the same bulk call as a full scan, then ancestors are re-summed. Byte totals stay file-system-derived.
- Hard links, APFS clones, firmlinks and permissions: reuse the existing full-scan rules on the re-enumerated
  subtree; add fixtures for hard links crossing the changed/unchanged boundary.
- Any uncertainty falls back to a full scan: UUID mismatch, wrap, dropped flags, schema/engine version
  change, root path missing, saved file corrupt or truncated, Full Disk Access changed since save.
- Always show when the data is incremental and when it was last fully verified; schedule a full verification
  scan periodically and offer "Rescan fully" always.
- Persistence safety: write atomically, version and checksum the file, never trust it across tree-id spaces
  (loading creates a new tree uid), bound its size, store under the app support folder, never include
  secrets. Memory and long-session behaviour must be re-measured with a persisted tree.

## Evidence required before any claim
1. Equivalence test: incremental result == fresh full scan, byte for byte, after scripted add/delete/grow/
   rename/hard-link/symlink/clone changes on a disposable fixture (CI, real FSEvents).
2. Recovery tests: forced UUID mismatch, simulated drop flag, corrupted/truncated saved tree, root removed.
3. Timings of full scan vs incremental refresh on the same folder, same runner, reported separately from UI
   time; no speedup claim without both numbers.
4. Soak: repeated incremental refreshes with footprint measured.

## Proposed epic (after E1-E7, or earlier if Karim prefers): E8 Incremental rescan
Tasks in dependency order: (a) serialize/deserialize tree with version + checksum + tests; (b) volume UUID and
event-ID bookkeeping; (c) FSEvents watcher in Swift/C feeding changed paths to Rust; (d) Rust partial rescan
and roll-up with equivalence tests; (e) fallback rules and status messaging; (f) CI equivalence + recovery
checks; (g) docs. CI and release at epic end only.
