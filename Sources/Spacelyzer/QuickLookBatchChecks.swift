#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import Foundation

// UNCOMPILED and UNRUN until a Mac run. Checks for the guarded batch-removal epic's fourth slice:
// multi-item Quick Look (payload ordering, validation, clamped focus, synchronous seam) and the
// shift-click focus fix (the programmatic selectRange now uses the same reconcile as the table
// path). Deterministic: the panel seam is substituted, so no real panel or file is touched, and
// the fixtures are model-only. Real QLPreviewPanel behavior is Mac-unverified.
@MainActor
enum QuickLookBatchChecks {
    static func run() {
        // 1. The payload keeps the selection's row order and opens on the focus item.
        let p = QuickLookController.payload(memberPaths: ["/a", "/b", "/c"], focusPath: "/b")
        Check.expect("quicklook-batch-payload-row-order-and-focus",
                     p?.paths == ["/a", "/b", "/c"] && p?.focus == 1,
                     "p=\(String(describing: p))")

        // 2. A focus path outside the set falls back to the first row; an empty set has no payload.
        let q = QuickLookController.payload(memberPaths: ["/a", "/b"], focusPath: "/zzz")
        let noPayload = QuickLookController.payload(memberPaths: [], focusPath: nil) == nil
        Check.expect("quicklook-batch-payload-focus-outside-falls-back-to-first",
                     q?.focus == 0 && noPayload,
                     "q=\(String(describing: q)) noPayload=\(noPayload)")

        // 3. An empty list and any relative path are refused before the panel seam is reached.
        var seen: [([URL], Int)] = []
        let saved = QuickLookController.presentItems
        QuickLookController.presentItems = { seen.append(($0, $1)) }
        defer { QuickLookController.presentItems = saved }
        let noEmpty = !QuickLookController.show(paths: [], focus: 0)
        let noRelative = !QuickLookController.show(paths: ["/abs", "rel/ative"], focus: 0)
        Check.expect("quicklook-batch-refuses-empty-and-relative-before-panel",
                     noEmpty && noRelative && seen.isEmpty, "seen=\(seen)")

        // 4. A valid set is presented synchronously, in order, with an out-of-range focus clamped
        //    to the last item.
        var hit = false
        QuickLookController.presentItems = { urls, idx in seen.append((urls, idx)); hit = true }
        let ok = QuickLookController.show(paths: ["/x", "/y", "/z"], focus: 99)
        Check.expect("quicklook-batch-show-presents-items-with-clamped-focus-synchronously",
                     ok && hit && seen.count == 1 && seen[0].0 == ["/x", "/y", "/z"].map { URL(fileURLWithPath: $0) } && seen[0].1 == 2,
                     "ok=\(ok) hit=\(hit) seen=\(seen)")

        // 5. Shift-click focus fix: the programmatic range path now agrees with the table reconcile.
        //    Upward from anchor 4 to 2: the table path focuses the last ADDED row in row order (3)
        //    and selectRange now matches; downward from 2 to 5 focuses the clicked row (5).
        let m = AppModel()
        m.outlineRows = [1, 2, 3, 4, 5].map { SpzRow(node: $0, depth: 1) }
        m.outlineIndex = Dictionary(uniqueKeysWithValues: [1, 2, 3, 4, 5].enumerated().map { ($0.element, $0.offset) })
        m.selectOnly(4); m.selectRange(to: 2)
        let upOK = m.selectedSet == [2, 3, 4] && m.selected == 3
        m.selectOnly(2); m.selectRange(to: 5)
        let downOK = m.selectedSet == [2, 3, 4, 5] && m.selected == 5
        Check.expect("shift-click-range-focus-matches-table-path",
                     upOK && downOK, "upOK=\(upOK) downOK=\(downOK) final=\(m.selectedSet) focus=\(String(describing: m.selected))")
    }
}
#endif
