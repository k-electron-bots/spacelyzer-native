# E4 removal concurrency audit

Source-review evidence for one release gate on the cleanup workflow: "safe off-main execution with current identity revalidation and no concurrent tree mutation/read." This page covers the concurrency half. Identity revalidation is not in the Trash path yet (no Swift caller of `spz_tree_check_identity`); that is tracked separately.

Evidence: `engine/src/tree.rs`, `engine/src/ffi.rs` and `Sources/Spacelyzer/AppModel.swift` read at `5239e02b`. The engine tests behind these invariants run on Linux; Mac behavior is unverified until a permitted Mac run. This is a source audit, not runtime race evidence.

## Mutation: copy, version, swap

`Tree.forget` (`tree.rs` 443-488) holds the per-tree `writer: Mutex<()>` for the whole capture-build-swap. It never writes the published table in place:

1. `prepare_forget` loads the current `Arc<SizeTable>`, copies the size array (`try_reserve_exact`; an allocation failure returns `MutationError::AllocFailed` and leaves the tree unchanged), zeroes the removed subtree on the copy, subtracts from ancestors, and builds a new `SizeTable` at `version + 1` with the removed root added to the table's sorted `forgotten` list.
2. Publication is one `ArcSwap<SizeTable>` pointer swap (`tree.rs` 171-174). Sizes, forgotten roots and the version live in one immutable allocation, so no reader can observe a torn mix of two versions.
3. A `forget` of an already-forgotten node is a no-op that returns the current version. A caught panic returns `MutationError::Panicked` with the tree unchanged.

Node names and paths are appended only while a scan builds the tree (`tree.rs` 561-578) and are never mutated after `seal`; `forget` touches only the size table. Name/path reads during a mutation are stable.

## Reads: old table or new table, never a torn one

Every read loads an `Arc<SizeTable>` (`table()` = `load_full`, or `capture()` under admission). A read in flight while a mutation commits sees either the old table or the new one; both are complete and internally consistent. Anything holding the old `Arc` keeps it alive; there is no use-after-free and no in-place write to race.

Status-checked FFI reads go further: they capture with an expected version and answer STALE when the table moved, BUSY when admission refuses, never an empty result dressed as a valid one (`ffi.rs`, status entry points from line 587).

## Capture admission and long passes

`capture()` (`tree.rs` 356-390) never waits. It refuses (BUSY) when the tree's running-capture count is at its cap (1 to 64, sized by table bytes against a 256 MB process-wide pinned-table budget) or when the reservation would pass the budget. A tree's first capture is always admitted, so an oversize tree is served one capture at a time, never zero.

The duplicate pass (`ffi.rs` 955-971) captures only to read the start version, releases the capture immediately ("a long pass must not block mutations"), then runs against immutable node storage and live file contents. When the pass ends it compares the report version and the live table version against the start version; any mutation during the pass makes the whole answer STALE. A long pass therefore neither blocks nor is corrupted by a concurrent `forget`.

Known bound, stated not fixed: legacy readers that call `table()` without admission pin old tables outside the capture budget accounting (noted in the `capture()` comment). Table bytes are bounded by what those callers actually hold; the Swift app holds at most its published tree and in-flight reads.

## Swift side

`CommitLane` (an actor) runs every `tree.forget` off the main actor and serially. `removalInFlight` serializes the filesystem Trash move itself (also off the main actor, `Task.detached`), and `mutationPending`/`commitsInFlight` refuse overlapping removal, undo and navigation while a commit is in flight (`AppModel.swift`). Reads that drive decisions use the status-checked accessors; BUSY is retried bounded, STALE with a filter recomputes the filter, anything else marks the view out of date instead of showing old numbers as current.

## Conclusion

The gate's "no concurrent tree mutation/read" holds by construction at the current source: immutable versioned tables, one writer mutex, one-pointer publication, admission-bounded captures, and STALE-on-mutation for every read that must be current. No engine change is needed for E4. The gate's identity-revalidation half is open and belongs to the Trash-path change, not this audit.

Not proven here: runtime behavior under real interleavings on a Mac (no run yet), and anything about the filesystem move itself (one lstat to one Trash call; the window between them is an identity-check question, not a table-concurrency question).
