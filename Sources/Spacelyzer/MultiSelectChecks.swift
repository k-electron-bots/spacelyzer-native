#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import CSpacelyzer   // SpzRow comes from the C target, like the production files
import Foundation

// UNCOMPILED and UNRUN until a Mac run. Regression checks for the multi-select model (the guarded
// batch-removal spec's second slice). selectedSet is the batch input; `selected` stays the focus
// and drives all existing single-selection behavior. Covered here: toggle membership with revision
// bumps, focus rules on add and remove, shift-range over outline row order in both directions,
// range without an anchor, filter-hidden members excluded from batch candidates, and clear.
// Deterministic: no scan, no filesystem, rows and the outline index set directly.
@MainActor
enum MultiSelectChecks {
    static func run() async {
        func model(rows: [UInt32]) -> AppModel {
            let m = AppModel()
            m.outlineRows = rows.map { SpzRow(node: $0, depth: 1) }
            m.outlineIndex = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element, $0.offset) })
            return m
        }

        // 1. Cmd-click toggles membership (adds then removes), and each set change bumps the
        //    revision: the outline table's coalescing remedy must see multi-select changes too.
        let m1 = model(rows: [1, 2, 3, 4])
        let r0 = m1.selectionRevision
        m1.selectOnly(1); m1.selectToggle(2); m1.selectToggle(3)
        let rAdded = m1.selectionRevision
        m1.selectToggle(2)
        Check.expect("multi-select-toggle-adds-and-removes-membership",
                     m1.selectedSet == [1, 3] && rAdded > r0 && m1.selectionRevision > rAdded,
                     "set=\(m1.selectedSet) revision=\(m1.selectionRevision)")

        // 2. Focus follows the click: adding focuses the new member; removing the focused member
        //    moves focus to the newest remaining member; removing the last member clears focus.
        let m2 = model(rows: [1, 2, 3])
        m2.selectOnly(1); m2.selectToggle(2); m2.selectToggle(3); m2.selectToggle(3)
        let afterRemove = m2.selected
        m2.selectToggle(2); m2.selectToggle(1)
        Check.expect("multi-select-focus-follows-toggle-and-removal",
                     afterRemove == 2 && m2.selectedSet.isEmpty && m2.selected == nil,
                     "afterRemove=\(String(describing: afterRemove)) final=\(String(describing: m2.selected)) set=\(m2.selectedSet)")

        // 3. Shift-click replaces the set with the outline-row slice between anchor and click, in
        //    row order, whichever direction the click goes. Focus: slice 4 routes selectRange
        //    through the same reconcile as the table path, so an upward range now focuses the last
        //    ADDED row in row order (3) instead of the clicked row (1) as before slice 4.
        let m3 = model(rows: [1, 2, 3, 4, 5])
        m3.selectOnly(2); m3.selectRange(to: 4)
        let forward = m3.selectedSet
        m3.selectOnly(4); m3.selectRange(to: 1)
        Check.expect("multi-select-range-covers-row-order-slice",
                     forward == [2, 3, 4] && m3.selectedSet == [1, 2, 3, 4] && m3.selected == 3,
                     "forward=\(forward) backward=\(m3.selectedSet) focus=\(String(describing: m3.selected))")

        // 4. Shift-click with no current focus anchors on the clicked row itself.
        let m4 = model(rows: [1, 2, 3])
        m4.selectRange(to: 2)
        Check.expect("multi-select-range-without-anchor-anchors-on-click",
                     m4.selectedSet == [2] && m4.selected == 2,
                     "set=\(m4.selectedSet) focus=\(String(describing: m4.selected))")

        // 5. Filter-hidden members stay selected but are excluded from batch candidates: drop a
        //    member from the outline (as a filter change would) and it leaves batchCandidateIDs
        //    while remaining in the set.
        let m5 = model(rows: [1, 2, 3])
        m5.selectOnly(1); m5.selectToggle(2); m5.selectToggle(3)
        m5.outlineRows.removeAll { $0.node == 2 }; m5.outlineIndex[2] = nil
        Check.expect("multi-select-hidden-members-excluded-from-batch-candidates",
                     m5.selectedSet == [1, 2, 3] && m5.batchCandidateIDs == [1, 3],
                     "set=\(m5.selectedSet) candidates=\(m5.batchCandidateIDs)")

        // 6. Clear empties the set and the focus.
        let m6 = model(rows: [1, 2])
        m6.selectOnly(1); m6.selectToggle(2); m6.clearSelectionSet()
        Check.expect("multi-select-clear-resets-set-and-focus",
                     m6.selectedSet.isEmpty && m6.selected == nil,
                     "set=\(m6.selectedSet) focus=\(String(describing: m6.selected))")
    }
}
#endif
