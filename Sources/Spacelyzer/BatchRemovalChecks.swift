#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import Foundation

// UNCOMPILED and UNRUN until a Mac run. Regression checks for batch removal PLANNING (the guarded
// batch-removal spec's first slice). The planner executes nothing: it only decides which candidate
// paths a batch may move through the existing per-item flow. Covered here: per-item gates pass
// through unchanged, the batch keep-one rule refuses exactly one deterministic copy when a batch
// covers a whole duplicate group, unknown paths are refused, non-group items plan on their own,
// and an out-of-date model refuses everything. Deterministic: a scanned fixture tree, fresh
// AppModel per case, no filesystem mutation.
@MainActor
enum BatchRemovalChecks {
    static func run() async {
        let names = ["batch-removal-single-copy-of-group-approved",
                     "batch-removal-all-copies-keeps-one-deterministically",
                     "batch-removal-unknown-path-refused",
                     "batch-removal-non-group-item-approved",
                     "batch-removal-out-of-date-model-refuses-all"]
        let fm = FileManager.default
        let d = fm.temporaryDirectory.appendingPathComponent("spz-batch-\(UUID().uuidString)")
        try! fm.createDirectory(at: d, withIntermediateDirectories: true)
        try! Data(repeating: 7, count: 10_000).write(to: d.appendingPathComponent("dupA.bin"))
        try! Data(repeating: 7, count: 10_000).write(to: d.appendingPathComponent("dupB.bin"))
        try! Data(repeating: 7, count: 10_000).write(to: d.appendingPathComponent("dupC.bin"))
        try! Data(repeating: 3, count: 10_000).write(to: d.appendingPathComponent("solo.bin"))
        defer { try? fm.removeItem(at: d) }
        guard let t = await ScanSession(root: d.path, excludes: [])?.run(progress: { _ in }) else {
            for n in names { Check.expect(n, false, "fixture") }; return
        }
        let pathA = "\(d.path)/dupA.bin", pathB = "\(d.path)/dupB.bin", pathC = "\(d.path)/dupC.bin"
        let solo = "\(d.path)/solo.bin"
        let group = [pathA, pathB, pathC]

        // 1. One copy of a group in a batch passes (other live copies remain).
        let m1 = AppModel(); m1.tree = t
        let p1 = BatchRemoval.plan([pathA], groups: [group], in: m1)
        Check.expect("batch-removal-single-copy-of-group-approved",
                     p1.approved.map { $0.path } == [pathA] && p1.refused.isEmpty,
                     "approved=\(p1.approved.map { $0.path }) refused=\(p1.refused)")

        // 2. A batch naming every live copy keeps exactly one: the path that sorts first, whatever
        // the input order; repeated candidates collapse.
        let m2 = AppModel(); m2.tree = t
        let p2 = BatchRemoval.plan([pathC, pathB, pathA, pathC], groups: [group], in: m2)
        Check.expect("batch-removal-all-copies-keeps-one-deterministically",
                     p2.approved.map { $0.path } == [pathC, pathB]
                         && p2.refused.count == 1 && p2.refused[0].path == pathA
                         && p2.refused[0].reason == "This batch would remove every copy of its duplicate group. One copy is always kept.",
                     "approved=\(p2.approved.map { $0.path }) refused=\(p2.refused)")

        // 3. A path the live tree does not contain is refused with the not-in-results reason.
        let m3 = AppModel(); m3.tree = t
        let gone = "\(d.path)/gone.bin"
        let p3 = BatchRemoval.plan([gone], groups: [[gone, pathA]], in: m3)
        Check.expect("batch-removal-unknown-path-refused",
                     p3.approved.isEmpty && p3.refused.count == 1
                         && p3.refused[0].reason == "This copy is not in the current results. Rescan to refresh.",
                     "refused=\(p3.refused)")

        // 4. A candidate in no listed group plans on its own (outline/treemap multi-select shape).
        let m4 = AppModel(); m4.tree = t
        let p4 = BatchRemoval.plan([solo], groups: [], in: m4)
        Check.expect("batch-removal-non-group-item-approved",
                     p4.approved.map { $0.path } == [solo] && p4.refused.isEmpty,
                     "approved=\(p4.approved.map { $0.path }) refused=\(p4.refused)")

        // 5. An out-of-date model refuses the whole batch with the coherence reason.
        let m5 = AppModel(); m5.tree = t
        m5.viewOutOfDate = true; m5.outOfDateReason = "test out of date"
        let p5 = BatchRemoval.plan([pathA, solo], groups: [group], in: m5)
        Check.expect("batch-removal-out-of-date-model-refuses-all",
                     p5.approved.isEmpty && p5.refused.count == 2
                         && p5.refused.allSatisfy { $0.reason == m5.coherenceNotice },
                     "refused=\(p5.refused)")
    }
}
#endif
