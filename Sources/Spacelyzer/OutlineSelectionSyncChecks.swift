#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import Foundation

// UNCOMPILED and UNRUN until a Mac run. Regression checks for the outline table-to-model selection
// reconcile (guarded batch-removal spec's third slice). The table owns click mechanics; reconcile
// folds its selection into the model's ordered set + focus. Covered here: added row focuses,
// removing an unfocused member keeps focus, removing the focused member moves focus to the last
// remaining member in row order, empty clears focus, and the model set normalizes to row order.
// Deterministic: pure function plus model-only fixtures, no mounted table, no filesystem.
@MainActor
enum OutlineSelectionSyncChecks {
    static func run() async {
        // 1. A cmd-click adding a row makes it the focus; the set follows the table's row order.
        let a = OutlineSelectionSync.reconcile(previous: [1, 2], current: [1, 2, 3], previousFocus: 2)
        Check.expect("outline-sync-added-row-becomes-focus",
                     a.set == [1, 2, 3] && a.focus == 3,
                     "set=\(a.set) focus=\(String(describing: a.focus))")

        // 2. Removing an UNFOCUSED member keeps the focus where it was.
        let b = OutlineSelectionSync.reconcile(previous: [1, 2, 3], current: [1, 3], previousFocus: 3)
        Check.expect("outline-sync-removal-of-other-keeps-focus",
                     b.set == [1, 3] && b.focus == 3,
                     "set=\(b.set) focus=\(String(describing: b.focus))")

        // 3. Removing the FOCUSED member moves focus to the last remaining member in row order.
        let c = OutlineSelectionSync.reconcile(previous: [1, 2, 3], current: [1, 3], previousFocus: 2)
        Check.expect("outline-sync-removal-moves-focus-to-last-row-order-member",
                     c.set == [1, 3] && c.focus == 3,
                     "set=\(c.set) focus=\(String(describing: c.focus))")

        // 4. Deselecting everything clears the set and the focus.
        let d = OutlineSelectionSync.reconcile(previous: [1], current: [], previousFocus: 1)
        Check.expect("outline-sync-empty-clears-focus",
                     d.set.isEmpty && d.focus == nil,
                     "set=\(d.set) focus=\(String(describing: d.focus))")

        // 5. The model normalizes the set to outline row order after programmatic toggles, so the
        //    table-driven path and the API agree (focus fallback, Quick Look cycling). Members the
        //    outline index does not know keep their relative order at the end.
        let m = AppModel()
        m.outlineRows = [1, 2, 3, 4].map { SpzRow(node: $0, depth: 1) }
        m.outlineIndex = Dictionary(uniqueKeysWithValues: [1, 2, 3, 4].enumerated().map { ($0.element, $0.offset) })
        m.selectOnly(3); m.selectToggle(1); m.selectToggle(4); m.selectToggle(99)
        Check.expect("multi-select-set-normalizes-to-row-order",
                     m.selectedSet == [1, 3, 4, 99] && m.selected == 99,
                     "set=\(m.selectedSet) focus=\(String(describing: m.selected))")
    }
}
#endif
