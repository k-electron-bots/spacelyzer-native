import Foundation

// UNCOMPILED and UNRUN until a Mac run. Batch removal planning (spec: guarded batch removal,
// owner decision 2026-10-11, channel record). This slice PLANS ONLY: no multi-select UI, no Trash
// execution, no history changes. Execution in a later slice must call the existing per-item flow
// (the identity check and Trash path behind confirmRemoval) once per approved item - batch must
// never get its own deletion path.
//
// Keep-one across the whole batch: the per-item gate (DuplicateRemoval.blockedReason) already
// refuses the last LIVE copy of a group, but it sees the tree as it is NOW. A batch naming every
// live copy of a group would pass that check item by item while still emptying the group, so the
// planner refuses one copy per fully-covered group: the one whose path sorts first, so the kept
// copy is deterministic and reviewable. Capped duplicate reports stay report-only: only LISTED
// paths may appear in a group, and a candidate belonging to no listed group is planned on its own.

enum BatchRemoval {
    struct Plan {
        /// Candidates that passed every gate, in input order.
        var approved: [(path: String, id: UInt32)] = []
        /// Candidates refused, in input order, each with the user-facing reason.
        var refused: [(path: String, reason: String)] = []
    }

    /// Plans one batch. `candidates` are exact paths (duplicates collapse to their first
    /// occurrence); `groups` are the LISTED member paths of each duplicate group from the report
    /// being acted on ([] for a batch from outside the duplicates review). Every candidate faces
    /// the same live-tree gates as the outline/treemap Trash buttons, then the batch keep-one rule.
    @MainActor
    static func plan(_ candidates: [String], groups: [[String]], in model: AppModel) -> Plan {
        var plan = Plan()
        var seen = Set<String>()
        var groupOf: [String: Int] = [:]
        for (index, group) in groups.enumerated() {
            for member in group where groupOf[member] == nil { groupOf[member] = index }
        }

        for path in candidates where seen.insert(path).inserted {
            if let groupIndex = groupOf[path] {
                // Listed group member: the exact per-item gates of the duplicates review, keep-one included.
                if let reason = DuplicateRemoval.blockedReason(path, groupPaths: groups[groupIndex], in: model) {
                    plan.refused.append((path, reason))
                } else if let id = DuplicateRemoval.liveID(path, in: model) {
                    plan.approved.append((path, id))
                } else {
                    plan.refused.append((path, "No scan is loaded."))
                }
            } else {
                // No listed group: keep-one does not apply (the item is not a known duplicate);
                // the other gates are the same ones the outline/treemap Trash buttons use.
                guard model.tree != nil else { plan.refused.append((path, "No scan is loaded.")); continue }
                guard let id = DuplicateRemoval.liveID(path, in: model) else {
                    plan.refused.append((path, "This item is not in the current results. Rescan to refresh."))
                    continue
                }
                if let reason = model.removalBlockedReason(id) {
                    plan.refused.append((path, reason))
                } else {
                    plan.approved.append((path, id))
                }
            }
        }

        // Batch keep-one: a group loses at most (live copies - 1) to one batch. When the batch
        // covers every live copy, the copy whose path sorts first is refused and kept.
        for group in groups {
            let live = group.filter { DuplicateRemoval.liveID($0, in: model) != nil }
            let survivors = live.filter { member in !plan.approved.contains { $0.path == member } }
            let approvedInGroup = plan.approved.filter { group.contains($0.path) }
            guard survivors.isEmpty, !approvedInGroup.isEmpty else { continue }
            guard let kept = approvedInGroup.map({ $0.path }).sorted().first else { continue }
            plan.approved.removeAll { $0.path == kept }
            plan.refused.append((kept, "This batch would remove every copy of its duplicate group. One copy is always kept."))
        }
        return plan
    }
}
