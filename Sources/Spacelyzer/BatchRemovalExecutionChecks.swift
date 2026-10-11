#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import CSpacelyzer   // SpzRow comes from the C target, like the production files
import Foundation

// UNCOMPILED and UNRUN until a Mac run. Checks for the guarded batch-removal epic's fifth slice:
// batch execution iterates the approved items through the SAME per-item identity-checked Trash
// path (selection row order, one journal entry per item with its own size, one identity check per
// item); a failing or refused item is skipped and reported while the rest complete; and the
// slice-5 preview-target rule (a fully filter-hidden set previews nothing). Deterministic: scanned
// fixture trees, a fresh AppModel per case, Trash and identity seams mocked - no real Trash move
// and no panel. The post-batch selection and outline refresh are the mounted table's business and
// are not covered here.
@MainActor
enum BatchRemovalExecutionChecks {
    static func run() async {
        let names = ["batch-execution-moves-each-item-through-per-item-path",
                     "batch-execution-failure-skips-and-reports-rest-complete",
                     "batch-execution-identity-refusal-skips-item",
                     "preview-targets-hidden-set-previews-nothing",
                     "preview-targets-empty-set-falls-back-to-focus"]
        let fm = FileManager.default
        let d = fm.temporaryDirectory.appendingPathComponent("spz-bexec-\(UUID().uuidString)")
        try! fm.createDirectory(at: d, withIntermediateDirectories: true)
        try! Data(repeating: 1, count: 1_000).write(to: d.appendingPathComponent("a.bin"))
        try! Data(repeating: 2, count: 2_000).write(to: d.appendingPathComponent("b.bin"))
        try! Data(repeating: 3, count: 3_000).write(to: d.appendingPathComponent("c.bin"))
        defer { try? fm.removeItem(at: d) }
        guard let t = await ScanSession(root: d.path, excludes: [])?.run(progress: { _ in }),
              let a = t.find(path: "\(d.path)/a.bin"), let b = t.find(path: "\(d.path)/b.bin"),
              let c = t.find(path: "\(d.path)/c.bin"), a != 0, b != 0, c != 0 else {
            for n in names { Check.expect(n, false, "fixture") }; return
        }

        // One model per case, wired with the fixture tree and a three-row outline.
        func model() -> AppModel {
            let m = AppModel()
            m.tree = t
            m.outlineRows = [a, b, c].map { SpzRow(node: $0, depth: 1) }
            m.outlineIndex = Dictionary(uniqueKeysWithValues: [a, b, c].enumerated().map { ($0.element, $0.offset) })
            m.selectOnly(a); m.selectToggle(b); m.selectToggle(c)
            return m
        }

        // 1. Full batch: every item moves through the per-item path in selection row order; one
        //    identity check and one journal entry per item, each with its own recorded size.
        let m1 = model()
        var trashed: [String] = []
        m1.trashItem = { url in trashed.append(url.lastPathComponent); return url }
        var identityCalls: [UInt32] = []
        m1.identityCheck = { _, id in identityCalls.append(id); return .same }
        m1.proposeBatchRemoval()
        let proposed = m1.pendingBatchRemoval?.items.map { $0.id } ?? []
        m1.confirmBatchRemoval()
        await m1.removalTask?.value
        let sizes = m1.lastRemoved.map { $0.size }
        Check.expect("batch-execution-moves-each-item-through-per-item-path",
                     proposed == [a, b, c] && trashed == ["a.bin", "b.bin", "c.bin"] && identityCalls == [a, b, c]
                     && m1.lastRemoved.count == 3 && sizes == [1_000, 2_000, 3_000]
                     && m1.removalMessage == "Moved 3 of 3 items to the Trash.",
                     "proposed=\(proposed) trashed=\(trashed) identity=\(identityCalls) journal=\(m1.lastRemoved.count) sizes=\(sizes) msg=\(m1.removalMessage ?? "nil")")

        // 2. A failing item is skipped and reported; the rest of the batch still completes.
        let m2 = model()
        var trashed2: [String] = []
        m2.trashItem = { url in
            if url.lastPathComponent == "b.bin" { throw CocoaError(.fileWriteUnknown) }
            trashed2.append(url.lastPathComponent); return url
        }
        m2.identityCheck = { _, _ in .same }
        m2.proposeBatchRemoval()
        m2.confirmBatchRemoval()
        await m2.removalTask?.value
        let msg2 = m2.removalMessage ?? ""
        Check.expect("batch-execution-failure-skips-and-reports-rest-complete",
                     trashed2 == ["a.bin", "c.bin"] && m2.lastRemoved.count == 2
                     && msg2.hasPrefix("Moved 2 of 3 items to the Trash.") && msg2.contains("Skipped 1:") && msg2.contains("b.bin"),
                     "trashed=\(trashed2) journal=\(m2.lastRemoved.count) msg=\(msg2)")

        // 3. An identity refusal skips that item before the Trash seam is reached; the rest move.
        let m3 = model()
        var trashed3: [String] = []
        m3.trashItem = { url in trashed3.append(url.lastPathComponent); return url }
        m3.identityCheck = { _, id in id == c ? .replaced : .same }
        m3.proposeBatchRemoval()
        m3.confirmBatchRemoval()
        await m3.removalTask?.value
        let msg3 = m3.removalMessage ?? ""
        Check.expect("batch-execution-identity-refusal-skips-item",
                     trashed3 == ["a.bin", "b.bin"] && m3.lastRemoved.count == 2
                     && msg3.hasPrefix("Moved 2 of 3 items to the Trash.") && msg3.contains("Skipped 1:") && msg3.contains("c.bin"),
                     "trashed=\(trashed3) journal=\(m3.lastRemoved.count) msg=\(msg3)")

        // 4. Slice-5 fix: a non-empty but fully filter-hidden set previews NOTHING - a hidden item
        //    is never handed to the panel (before the fix the hidden focus was previewed).
        Check.expect("preview-targets-hidden-set-previews-nothing",
                     AppModel.previewTargets(set: [1, 2], visibleCandidates: [], focus: 1).isEmpty,
                     "targets=\(AppModel.previewTargets(set: [1, 2], visibleCandidates: [], focus: 1))")

        // 5. An EMPTY set falls back to the focus alone (the single-selection behavior), and a
        //    visible set returns its candidates in the given order.
        Check.expect("preview-targets-empty-set-falls-back-to-focus",
                     AppModel.previewTargets(set: [], visibleCandidates: [], focus: 7) == [7]
                     && AppModel.previewTargets(set: [1, 2], visibleCandidates: [2, 1], focus: 2) == [2, 1]
                     && AppModel.previewTargets(set: [], visibleCandidates: [], focus: nil).isEmpty,
                     "single=\(AppModel.previewTargets(set: [], visibleCandidates: [], focus: 7))")
    }
}
#endif
