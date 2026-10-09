#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import Foundation

// UNCOMPILED and UNRUN until a Mac run. Regression checks for the duplicate-review removal wiring
// (E6): a listed member resolves against the LIVE tree (a stale report path is refused with a
// reason), the outline/treemap removal gates pass through unchanged, and keep-one-copy holds -
// the last remaining copy of a group is never offered removal. Only the resolution/gate logic is
// exercised here; the actual Trash move is the E4 flow (IdentityGateChecks, RemovalHistoryChecks).
// Deterministic: a scanned fixture tree, fresh AppModel per case, no filesystem mutation.
@MainActor
enum DuplicatesRemovalChecks {
    static func run() async {
        let names = ["duplicates-removal-listed-member-resolves-to-live-node",
                     "duplicates-removal-unknown-path-and-no-tree-refused-with-reason",
                     "duplicates-removal-blocked-reason-passes-removal-gates-through",
                     "duplicates-removal-last-remaining-copy-never-offered",
                     "duplicates-removal-propose-through-live-id-opens-confirmation"]
        let fm = FileManager.default
        let d = fm.temporaryDirectory.appendingPathComponent("spz-dupr-\(UUID().uuidString)")
        try! fm.createDirectory(at: d, withIntermediateDirectories: true)
        try! Data(repeating: 9, count: 10_000).write(to: d.appendingPathComponent("dupA.bin"))
        try! Data(repeating: 9, count: 10_000).write(to: d.appendingPathComponent("dupB.bin"))
        defer { try? fm.removeItem(at: d) }
        guard let t = await ScanSession(root: d.path, excludes: [])?.run(progress: { _ in }),
              let a = t.find(path: "\(d.path)/dupA.bin"), let b = t.find(path: "\(d.path)/dupB.bin"), a != 0, b != 0 else {
            for n in names { Check.expect(n, false, "fixture") }; return
        }
        let pathA = "\(d.path)/dupA.bin", pathB = "\(d.path)/dupB.bin"
        let group = [pathA, pathB]

        // 1. A listed member resolves to its live-tree node id, and a quiet model offers it.
        let m1 = AppModel()
        m1.tree = t
        Check.expect("duplicates-removal-listed-member-resolves-to-live-node",
                     DuplicateRemoval.liveID(pathA, in: m1) == a && DuplicateRemoval.liveID(pathB, in: m1) == b
                     && DuplicateRemoval.blockedReason(pathA, groupPaths: group, in: m1) == nil,
                     "a=\(String(describing: DuplicateRemoval.liveID(pathA, in: m1))) b=\(String(describing: DuplicateRemoval.liveID(pathB, in: m1))) reason=\(DuplicateRemoval.blockedReason(pathA, groupPaths: group, in: m1) ?? "nil")")

        // 2. A path the live tree does not contain is refused with the not-in-results reason; with
        // no tree at all the reason says no scan is loaded.
        let m2 = AppModel()
        m2.tree = t
        let gone = "\(d.path)/gone.bin"
        let r2 = DuplicateRemoval.blockedReason(gone, groupPaths: [gone, pathA], in: m2)
        let m2b = AppModel()
        let r2b = DuplicateRemoval.blockedReason(pathA, groupPaths: group, in: m2b)
        Check.expect("duplicates-removal-unknown-path-and-no-tree-refused-with-reason",
                     DuplicateRemoval.liveID(gone, in: m2) == nil && r2 == "This copy is not in the current results. Rescan to refresh."
                     && DuplicateRemoval.liveID(pathA, in: m2b) == nil && r2b == "No scan is loaded.",
                     "gone=\(r2 ?? "nil") noTree=\(r2b ?? "nil")")

        // 3. The outline/treemap removal gates pass through unchanged: an out-of-date model refuses
        // with the coherence reason, not a duplicates-specific one.
        let m3 = AppModel()
        m3.tree = t
        m3.viewOutOfDate = true
        m3.outOfDateReason = "test out of date"
        let r3 = DuplicateRemoval.blockedReason(pathA, groupPaths: group, in: m3)
        Check.expect("duplicates-removal-blocked-reason-passes-removal-gates-through",
                     r3 != nil && r3 == m3.coherenceNotice && (r3 ?? "").contains("test out of date"),
                     "reason=\(r3 ?? "nil")")

        // 4. Keep-one-copy: when the only OTHER listed member no longer resolves in the live tree,
        // the remaining copy is never offered removal.
        let m4 = AppModel()
        m4.tree = t
        let r4 = DuplicateRemoval.blockedReason(pathA, groupPaths: [pathA, gone], in: m4)
        let bothResolve = DuplicateRemoval.blockedReason(pathA, groupPaths: group, in: m4) == nil
        Check.expect("duplicates-removal-last-remaining-copy-never-offered",
                     r4 == "The last remaining copy of this duplicate group. One copy is always kept." && bothResolve,
                     "lastCopy=\(r4 ?? "nil") bothResolve=\(bothResolve)")

        // 5. The wired path opens the E4 confirmation for the resolved live node.
        let m5 = AppModel()
        m5.tree = t
        if let id = DuplicateRemoval.liveID(pathB, in: m5) { m5.proposeRemoval(of: id) }
        Check.expect("duplicates-removal-propose-through-live-id-opens-confirmation",
                     m5.pendingRemoval == b,
                     "pending=\(String(describing: m5.pendingRemoval)) want=\(b)")
    }
}
#endif
