# Index-assisted first results and dua-cli inspiration
October 2, 2026. Evaluation only; no implementation or speed claim.

Use the OS index as an accelerant. Run a narrow, bounded Spotlight candidate query concurrently with the authoritative filesystem scan. Compare this with streaming authoritative scan results, inspired by dua-cli. Do not require persistence or FSEvents before testing the first-results idea: those accelerate repeat scans and are a separate outcome.

## Recommended experiment
1. Introduce bounded Rust scan-result events and publish a small Largest preview every 250ms off-main. Keep the full-tree final publication and exact accounting unchanged.
2. Start a root-scoped asynchronous Spotlight query in parallel. Fetch paths and indexed sizes as discovery/ranking hints. Validate candidates through current filesystem metadata off-main before presenting allocated bytes. Do not enumerate the entire index as a second tree. Benchmark NSMetadataQuery against low-level MDQuery if query breadth causes unbounded result materialization; a cap must not be claimed until verified with the exact API/SDK.
3. Separate preview records from arena node IDs. Bind every result to scan generation and root, enforce root containment and existing volume/link rules, reject vanished or inaccessible paths. Use filesystem identity for reconciliation, not only a path string. Bound memory, work and queue size; cancel on root/filter change or full-scan completion.
4. Label the list 'Early results - scanning'. Even stat-verified entries are not a complete ranking. Never sum preview bytes into folder, treemap or volume totals. Disable Trash on preview rows; authoritative selection and existing confirmation are required.
5. Promote results when the full scan reaches them and retire the preview when the complete tree lands. Empty, excluded, stale, rebuilding, disabled or slow indexes must not delay the normal scan. A cloud placeholder must not cause content download just to size a candidate.

## Interaction requirement
Karim's October2 direction: the processing/UI split and nonintrusive, obvious, nonjanky transitions apply across Spacelyzer and Sentinel. For this experiment, show one quiet inline scan-state cue, never a popup or blocking spinner. Preserve the visible row anchor, scroll offset and selection identity while results arrive. Do not re-sort rows beneath the pointer or during keyboard navigation; queue ranking changes until the user is idle or asks to refresh. Replace provisional labels in place, not with a new screen. Use stable identities and generation checks, bounded off-main work and a single batched publication. Respect Reduce Motion. Test active hover, selection and scrolling while previews arrive, including the final tree transition, before calling this achieved. This is a requirement, not current implementation.

## Measure before choosing
Compare full-scan-only, streamed authoritative scan, and streamed scan plus index candidates on the same folders and hardware, both cold and warm cache. Record time to first visible filesystem-validated candidate, time to first useful top-N list, full completion, CPU, resident memory, bytes/entries inspected and main-thread stalls separately. Verify identical final results with/without acceleration after add/delete/rename/grow/hard-link/permission changes, root swaps and cancellation. Test Spotlight exclusions, stale/empty results, huge scopes, network/removable volumes, cloud placeholders and query errors. An index that helps first paint but harms full completion is a tradeoff to report, not an unconditional improvement.

## dua-cli: borrow the useful engineering, not the interface
Reviewed upstream commit 58d727cff755b74634ab0794fe15b20d2db053fa. Its traversal sends Entry and Finished events through a bounded channel (100), stages cleanup candidates, and throttles interactive state publication to 250ms. It exposes useful results while work continues. Spacelyzer already scans directories in parallel and reports item/byte progress, but returns a flattened tree only at the end. Bounded progressive results are the main transferable idea, not replacing getattrlistbulk with another walker without evidence.

Its targeted refresh and refresh-clears-marks behavior fit future inspect/remove and scan-control work. Its explicit review of cleanup candidates and multi-stage deletion are useful interaction references. Keep Spacelyzer's native Mac presentation, Trash-only policy, no automatic deletion and full-path confirmations. Its ignore patterns illustrate explicit exclusions; never silently exclude common build/cache folders from accounting. APFS clone deduplication is opt-in upstream and remains a separate accounting research task here, not a proven current capability.

Upstream is MIT, copyright Sebastian Thiel (2019). This evaluation copies no implementation. Any later copied code or substantial portion must retain the copyright and MIT notice; new dependencies need project review. Upstream speed statements are its own claims, not our measured baseline.

## What is known, and what is not
Apple documents asynchronous batched Spotlight queries, scopes and sorting by metadata keys. kMDItemPath is retrievable but not usable as a query/sort key. Apple describes kMDItemFSSize as 'Size, in bytes, of the file on disk'; this text alone does not prove equivalence to our block-derived allocated-byte, hard-link and volume accounting. Verify the candidate with our filesystem metadata rather than making that equivalence claim. Query completion means the query is done, not that the selected filesystem is completely accounted for. Public API behavior establishes feasibility, not latency on Karim's Mac. Nothing here is implemented.

## Sources
- Apple query programming guide: https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/SpotlightQuery/Concepts/QueryingMetadata.html
- Apple metadata attributes: https://developer.apple.com/library/archive/documentation/CoreServices/Reference/MetadataAttributesRef/Reference/CommonAttrs.html
- Apple NSMetadataQuery API: https://developer.apple.com/documentation/Foundation/NSMetadataQuery
- Apple API comparison: https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/SpotlightQuery/Concepts/Introduction.html
- Apple Spotlight exclusions: https://support.apple.com/en-gb/guide/mac-help/mchl1bb43b84/mac
- Upstream dua overview and license: https://github.com/Byron/dua-cli
- Exact reviewed traversal: https://github.com/Byron/dua-cli/blob/58d727cff755b74634ab0794fe15b20d2db053fa/src/traverse.rs
- Community query-breadth latency report (anecdote, not benchmark): https://stackoverflow.com/questions/68622160/how-to-limit-the-number-of-results-returned-from-nsmetadataquery
