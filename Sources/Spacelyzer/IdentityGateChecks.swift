#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import Foundation

// UNCOMPILED and UNRUN until a Mac run. Regression checks for the pre-Trash identity gate
// (E4b): the revalidation runs OFF the main actor inside the removal task, immediately before
// the Trash move; any verdict but .same refuses and moves NOTHING (the Trash seam must not be
// reached, no filesystem epoch is counted); a .same verdict proceeds and journals the removal.
// Deterministic: the identity seam parks on a bounded semaphore, settles are bounded polls. The
// Trash operation and the identity check are injected seams, so no real file is touched and any
// verdict can be forced. The verdict mapping itself is engine-covered (Linux tests); the real
// lstat path is Mac-unverified.
@MainActor
enum IdentityGateChecks {
    /// Thread-safe call counter for the injected Trash seam (it is called off the main actor).
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
    /// Bounded: polls cond for about 3 s.
    private static func settle(_ cond: @MainActor () -> Bool) async { for _ in 0..<300 where !cond() { try? await Task.sleep(nanoseconds: 10_000_000) } }

    /// One model with the fixture tree injected, ready for a proposed removal of `victim`.
    private static func model(_ t: Tree, _ trash: Counter) -> AppModel {
        let m = AppModel()
        m.tree = t
        m.trashItem = { _ in trash.bump(); return URL(fileURLWithPath: "/tmp/spz-idc-fake-trashed") }
        return m
    }

    static func run() async {
        let names = ["identity-gate-runs-off-main-before-trash", "identity-gate-replaced-refuses-and-moves-nothing",
                     "identity-gate-gone-refuses-and-moves-nothing", "identity-gate-engine-fault-refuses",
                     "identity-gate-same-proceeds-and-journals"]
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("spz-idc-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try! Data(repeating: 5, count: 20_000).write(to: d.appendingPathComponent("victim.bin"))
        defer { try? FileManager.default.removeItem(at: d) }
        guard let t = await ScanSession(root: d.path, excludes: [])?.run(progress: { _ in }),
              let victim = t.find(path: "\(d.path)/victim.bin"), victim != 0 else {
            for n in names { Check.expect(n, false, "fixture") }; return
        }

        // 1. The check runs off the main actor BEFORE the move: with the identity seam parked on a
        // semaphore, confirmRemoval returns, the Trash seam is unreached, and only signaling lets the
        // move through. A main-actor check would park this test itself; a move before the check would
        // bump the counter while parked.
        let park = DispatchSemaphore(value: 0)
        let trash1 = Counter()
        let m1 = model(t, trash1)
        m1.identityCheck = { _, _ in _ = park.wait(timeout: .now() + 5); return .same }
        m1.proposeRemoval(of: victim)
        m1.confirmRemoval()
        let parkedOffMain = m1.removalInFlight && trash1.value == 0
        park.signal()
        await settle { !m1.removalInFlight && trash1.value == 1 }
        Check.expect("identity-gate-runs-off-main-before-trash", parkedOffMain && trash1.value == 1 && m1.lastRemoved.count == 1, "parkedOffMain=\(parkedOffMain) trash=\(trash1.value) removed=\(m1.lastRemoved.count)")

        // 2-4. replaced, gone and an engine fault all refuse: the Trash seam is never reached, no
        // removal is journaled, no filesystem epoch is counted, and the verdict's own message is shown.
        for (name, verdict) in [("identity-gate-replaced-refuses-and-moves-nothing", IdentityVerdict.replaced),
                                ("identity-gate-gone-refuses-and-moves-nothing", IdentityVerdict.gone),
                                ("identity-gate-engine-fault-refuses", IdentityVerdict.engineFault(code: -2))] {
            let trash = Counter()
            let m = model(t, trash)
            m.identityCheck = { _, _ in verdict }
            let epochBefore = m.fsEpoch
            m.proposeRemoval(of: victim)
            m.confirmRemoval()
            await settle { !m.removalInFlight }
            Check.expect(name, trash.value == 0 && m.pendingRemoval == nil && m.lastRemoved.isEmpty
                         && m.removalMessage == verdict.message && m.fsEpoch == epochBefore && !m.mutationPending,
                         "trash=\(trash.value) pending=\(String(describing: m.pendingRemoval)) removed=\(m.lastRemoved.count) message=\(m.removalMessage ?? "nil")")
        }

        // 5. .same proceeds: the move runs once, the removal is journaled, the engine commit settles.
        let trash5 = Counter()
        let m5 = model(t, trash5)
        m5.identityCheck = { _, _ in .same }
        m5.proposeRemoval(of: victim)
        m5.confirmRemoval()
        await settle { m5.lastRemoved.count == 1 && m5.commitsInFlight == 0 && !m5.removalInFlight }
        Check.expect("identity-gate-same-proceeds-and-journals", trash5.value == 1 && m5.lastRemoved.count == 1
                     && m5.lastRemoved[0].original.lastPathComponent == "victim.bin" && m5.commitsInFlight == 0,
                     "trash=\(trash5.value) removed=\(m5.lastRemoved.count) commits=\(m5.commitsInFlight)")
    }
}
#endif
