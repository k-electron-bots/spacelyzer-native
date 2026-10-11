import Foundation

// UNCOMPILED and UNRUN until a Mac run. Table-to-model selection reconcile (guarded batch-removal
// epic, slice 3). The outline table owns the click mechanics (cmd toggles, shift ranges) once
// multiple selection is on; this pure function folds the table's new selection into the model's
// ordered set + focus with the same rules as the programmatic API (selectToggle/selectRange):
// an added row becomes the focus, removing the focused member moves focus to the last remaining
// member in row order, and an empty set clears focus. Pure so the CI checks drive it without
// mounting a table.
enum OutlineSelectionSync {
    /// `previous`/`current` are node IDs in OUTLINE ROW ORDER (the table reports row order; the
    /// model normalizes to row order too). `previousFocus` is the model's current focus.
    static func reconcile(previous: [UInt32], current: [UInt32], previousFocus: UInt32?) -> (set: [UInt32], focus: UInt32?) {
        let added = current.filter { !previous.contains($0) }
        if let lastAdded = added.last { return (current, lastAdded) }
        if let f = previousFocus, current.contains(f) { return (current, f) }
        return (current, current.last)
    }
}
