#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import Foundation

// UNCOMPILED and UNRUN until a Mac run. Regression checks for the removal history (E4e): every
// successful removal is journaled (newest last), the alert Undo restores only the LATEST record,
// the history's per-item Put Back moves only the named record and keeps the rest, a collision
// keeps the record and overwrites nothing, a restore is refused while an engine commit is parked,
// and an unknown record id is a no-op. Deterministic: the Trash, identity and restore operations
// are injected seams, so no real file is touched and any outcome can be forced; settles are
// bounded polls. Real restore behavior on disk stays Mac-unverified until a permitted Mac run.
@MainActor
enum RemovalHistoryChecks {
    /// Thread-safe recorder for the injected restore seam (it is called off the main actor).
    private final class RestoreLog: @unchecked Sendable {
        private let lock = NSLock(); private var calls: [(from: String, to: String)] = []
        func record(_ from: URL, _ to: URL) { lock.lock(); calls.append((from.path, to.path)); lock.unlock() }
        var value: [(from: String, to: String)] { lock.lock(); defer { lock.unlock() }; return calls }
    }
    /// Bounded: polls cond for about 3 s.
    private static func settle(_ cond: @MainActor () -> Bool) async { for _ in 0..<300 where !cond() { try? await Task.sleep(nanoseconds: 10_000_000) } }
    /// Acts as the missing view exactly once per settled removal (the same pattern the async-removal
    /// suite uses): the layout surface publishes the current version, then the model must go quiet.
    /// Returns false when the model never goes quiet; the caller's check then fails on its own terms.
    private static func settleSurfaces(_ m: AppModel) async -> Bool {
        _ = await m.settleRemoval()
        await settle { m.outlineVersion == m.tree?.version && m.derivedVersion == m.tree?.version }
        if let v = m.tree?.version { m.layoutPublished(v) }
        await settle { !m.rowsPending }
        return !m.rowsPending && m.requiredVersion == nil
    }

    static func run() async {
        let names = ["removal-history-journals-every-removal-in-order", "removal-history-undo-restores-latest-only",
                     "removal-history-restore-one-keeps-the-other-journaled", "removal-history-restore-refused-while-commit-parked",
                     "removal-history-restore-collision-keeps-record", "removal-history-restore-unknown-id-is-a-no-op"]
        let fm = FileManager.default
        let d = fm.temporaryDirectory.appendingPathComponent("spz-rmh-\(UUID().uuidString)")
        try! fm.createDirectory(at: d, withIntermediateDirectories: true)
        try! Data(repeating: 7, count: 20_000).write(to: d.appendingPathComponent("a.bin"))
        try! Data(repeating: 8, count: 30_000).write(to: d.appendingPathComponent("b.bin"))
        defer { try? fm.removeItem(at: d) }
        guard let t = await ScanSession(root: d.path, excludes: [])?.run(progress: { _ in }),
              let a = t.find(path: "\(d.path)/a.bin"), let b = t.find(path: "\(d.path)/b.bin"), a != 0, b != 0 else {
            for n in names { Check.expect(n, false, "fixture") }; return
        }
        let pathA = "\(d.path)/a.bin", pathB = "\(d.path)/b.bin"

        // 1-2. Two removals journal two records in order; the alert Undo then restores ONLY the latest.
        // The Trash seam returns a fake trashed URL per call and touches nothing; the restore seam only records.
        let m1 = AppModel()
        m1.tree = t
        var trashN = 0
        m1.trashItem = { _ in trashN += 1; return URL(fileURLWithPath: "/tmp/spz-rmh-fake-trash-\(trashN)") }
        m1.identityCheck = { _, _ in .same }
        let log1 = RestoreLog()
        m1.restoreItem = { from, to in log1.record(from, to) }
        m1.proposeRemoval(of: a); m1.confirmRemoval()
        let s1 = await settleSurfaces(m1)
        m1.proposeRemoval(of: b); m1.confirmRemoval()
        let s2 = await settleSurfaces(m1)
        Check.expect("removal-history-journals-every-removal-in-order",
                     s1 && s2 && m1.lastRemoved.count == 2
                     && m1.lastRemoved[0].original.path == pathA && m1.lastRemoved[1].original.path == pathB
                     && m1.lastRemoved[0].id != m1.lastRemoved[1].id,
                     "settle=\(s1),\(s2) journal=\(m1.lastRemoved.map { $0.original.lastPathComponent })")
        m1.undoRemoval()
        await m1.settleRemoval()
        Check.expect("removal-history-undo-restores-latest-only",
                     log1.value.count == 1 && log1.value[0].from == "/tmp/spz-rmh-fake-trash-2" && log1.value[0].to == pathB
                     && m1.lastRemoved.count == 1 && m1.lastRemoved[0].original.path == pathA,
                     "restoreCalls=\(log1.value) journal=\(m1.lastRemoved.map { $0.original.lastPathComponent })")

        // 3. Per-item restore moves ONLY the named record: restoring the older of two keeps the newer journaled.
        let m2 = AppModel()
        m2.tree = t
        var trashN2 = 0
        m2.trashItem = { _ in trashN2 += 1; return URL(fileURLWithPath: "/tmp/spz-rmh2-fake-trash-\(trashN2)") }
        m2.identityCheck = { _, _ in .same }
        let log2 = RestoreLog()
        m2.restoreItem = { from, to in log2.record(from, to) }
        m2.proposeRemoval(of: a); m2.confirmRemoval()
        let s3 = await settleSurfaces(m2)
        m2.proposeRemoval(of: b); m2.confirmRemoval()
        let s4 = await settleSurfaces(m2)
        let olderID = m2.lastRemoved.count == 2 ? m2.lastRemoved[0].id : UUID()
        m2.restoreRemoved(id: olderID)
        await m2.settleRemoval()
        Check.expect("removal-history-restore-one-keeps-the-other-journaled",
                     s3 && s4 && log2.value.count == 1 && log2.value[0].from == "/tmp/spz-rmh2-fake-trash-1" && log2.value[0].to == pathA
                     && m2.lastRemoved.count == 1 && m2.lastRemoved[0].original.path == pathB,
                     "settle=\(s3),\(s4) restoreCalls=\(log2.value) journal=\(m2.lastRemoved.map { $0.original.lastPathComponent })")

        // 4. A restore is refused while the removal's engine commit is parked: the restore seam is never
        // reached, the record stays, and the busy message is shown. The gate is always opened afterwards.
        let m3 = AppModel()
        m3.tree = t
        m3.trashItem = { _ in URL(fileURLWithPath: "/tmp/spz-rmh3-fake-trash-1") }
        m3.identityCheck = { _, _ in .same }
        let log3 = RestoreLog()
        m3.restoreItem = { from, to in log3.record(from, to) }
        let gate = OpenGate()
        defer { gate.open() }   // never leave the commit parked if a check fails early
        m3.beforeCommit = { while !gate.isOpen { try? await Task.sleep(nanoseconds: 5_000_000) } }
        m3.proposeRemoval(of: a); m3.confirmRemoval()
        await settle { m3.commitsInFlight == 1 && !m3.removalInFlight }
        let parked = m3.commitsInFlight == 1 && m3.lastRemoved.count == 1
        m3.restoreRemoved(id: m3.lastRemoved.count == 1 ? m3.lastRemoved[0].id : UUID())
        let refused = m3.lastRemoved.count == 1 && log3.value.isEmpty && (m3.removalMessage ?? "").contains("still being applied")
        gate.open()
        await m3.settleRemoval()
        Check.expect("removal-history-restore-refused-while-commit-parked", parked && refused,
                     "parked=\(parked) refused=\(refused) restoreCalls=\(log3.value) message=\(m3.removalMessage ?? "nil")")

        // 5. A collision (the probe finds something already at the original path) keeps the record, calls
        // no restore, and overwrites nothing.
        let m4 = AppModel()
        m4.tree = t
        m4.trashItem = { _ in URL(fileURLWithPath: "/tmp/spz-rmh4-fake-trash-1") }
        m4.identityCheck = { _, _ in .same }
        let log4 = RestoreLog()
        m4.restoreItem = { from, to in log4.record(from, to) }
        m4.proposeRemoval(of: a); m4.confirmRemoval()
        let s5 = await settleSurfaces(m4)
        m4.restoreCollisionProbe = { _ in true }
        let id4 = m4.lastRemoved.count == 1 ? m4.lastRemoved[0].id : UUID()
        m4.restoreRemoved(id: id4)
        await m4.settleRemoval()
        Check.expect("removal-history-restore-collision-keeps-record",
                     s5 && m4.lastRemoved.count == 1 && log4.value.isEmpty && (m4.removalMessage ?? "").contains("already exists"),
                     "settle=\(s5) journal=\(m4.lastRemoved.count) restoreCalls=\(log4.value) message=\(m4.removalMessage ?? "nil")")

        // 6. An unknown record id is a no-op: no restore call, no message, journal untouched.
        let m5 = AppModel()
        let log5 = RestoreLog()
        m5.restoreItem = { from, to in log5.record(from, to) }
        m5.lastRemoved = [RemovedItem(original: URL(fileURLWithPath: pathA), trashed: URL(fileURLWithPath: "/tmp/spz-rmh5-fake-trash-1"), size: 1)]
        m5.restoreRemoved(id: UUID())
        Check.expect("removal-history-restore-unknown-id-is-a-no-op",
                     m5.lastRemoved.count == 1 && log5.value.isEmpty && m5.removalMessage == nil && !m5.removalInFlight && !m5.mutationPending,
                     "journal=\(m5.lastRemoved.count) restoreCalls=\(log5.value) message=\(m5.removalMessage ?? "nil")")
    }
}
#endif
