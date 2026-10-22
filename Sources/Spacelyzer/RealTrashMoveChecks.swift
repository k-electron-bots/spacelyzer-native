#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import Foundation

// UNCOMPILED and UNRUN until a Mac run. The REAL-Trash-move gate: every other removal check mocks
// the Trash/identity/restore seams, so no real Trash move has ever executed anywhere. This suite
// overrides NOTHING - AppModel's default seams (FileManager.trashItem, the engine lstat identity
// check, FileManager.moveItem restore, the file-exists collision probe) all run for real against a
// disposable fixture the suite creates and deletes. It proves the actual filesystem behavior the
// mocked suites only simulate: a real move lands in the Trash and journals, a real undo puts the
// item back, a post-scan change refuses the real move, and a real collision keeps both files.
// Wiring is proven on Linux by scripts/test-real-trash-checks.py and check-ordering-manifest.py,
// and the confinement/predicate logic by scripts/test-real-trash-gate.py (design-level behavioral
// checks, not execution of this Swift). The Swift behavior itself is UNVERIFIED until an approved
// Mac run executes it.
@MainActor
enum RealTrashMoveChecks {
    /// Bounded: polls cond for about 3 s. Same pattern as BatchUndoChecks.
    private static func settle(_ cond: @MainActor () -> Bool) async { for _ in 0..<300 where !cond() { try? await Task.sleep(nanoseconds: 10_000_000) } }
    /// Acts as the missing view exactly once per settled removal (copied from BatchUndoChecks): the
    /// engine commit after a real move leaves commitsInFlight/mutationPending/requiredVersion set,
    /// and undoRemoval REFUSES in that state - awaiting removalTask alone is not enough. The layout
    /// surface publishes the current version, then the model must go quiet. Returns false when the
    /// model never goes quiet; the caller's check then fails on its own terms.
    private static func settleSurfaces(_ m: AppModel) async -> Bool {
        _ = await m.settleRemoval()
        await settle { m.outlineVersion == m.tree?.version && m.derivedVersion == m.tree?.version }
        if let v = m.tree?.version { m.layoutPublished(v) }
        await settle { !m.rowsPending }
        return !m.rowsPending && m.requiredVersion == nil
    }

    /// The deferred cleanup may only ever delete THIS suite's own fixture files sitting in a Trash:
    /// a .Trash path whose name is one of the three fixture names (allowing the Finder's "a 2.bin"
    /// dedup suffix). Anything else is left alone - never an unrelated file.
    private static func isExpectedFixtureTrashItem(_ u: URL) -> Bool {
        let name = u.lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let stem = base.components(separatedBy: " ").first ?? ""
        return u.path.contains(".Trash") && (name as NSString).pathExtension == "bin" && ["a", "b", "c"].contains(stem)
    }

    static func run() async {
        let names = ["real-trash-move-executes-and-journals",
                     "real-trash-undo-restores-original",
                     "real-trash-identity-replaced-refuses-move",
                     "real-trash-restore-collision-keeps-both"]
        let fm = FileManager.default
        let d = fm.temporaryDirectory.appendingPathComponent("spz-rtm-\(UUID().uuidString)")
        try! fm.createDirectory(at: d, withIntermediateDirectories: true)
        // Allocated-byte distinct sizes (see BatchRemovalExecutionChecks: 1_000/5_000/9_000 land in
        // distinct allocation blocks on the runner's APFS).
        try! Data(repeating: 1, count: 1_000).write(to: d.appendingPathComponent("a.bin"))
        try! Data(repeating: 2, count: 5_000).write(to: d.appendingPathComponent("b.bin"))
        try! Data(repeating: 3, count: 9_000).write(to: d.appendingPathComponent("c.bin"))
        var trashedLeftovers: [URL] = []
        defer {
            // Every task was awaited before any exit from this scope, so nothing is in flight here.
            // Remove the fixture, then any of THIS suite's own files left in the Trash (expected
            // only for the collision case or after a mid-suite failure), each validated first.
            try? fm.removeItem(at: d)
            for u in trashedLeftovers where isExpectedFixtureTrashItem(u) { try? fm.removeItem(at: u) }
        }
        // Canonicalize with the same syscall as the engine (see RemovalHistoryChecks), then a HARD
        // SAFETY GATE before any real Trash call: the canonical fixture root must live under the
        // canonical temporary directory and carry this suite's unique marker. Any doubt fails every
        // check and touches nothing.
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(d.path, &buf) != nil else {
            let err = String(cString: strerror(errno))
            for n in names { Check.expect(n, false, "realpath failed for \(d.path): \(err)") }; return
        }
        let root = String(cString: buf)
        var tbuf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(fm.temporaryDirectory.path, &tbuf) != nil else {
            for n in names { Check.expect(n, false, "realpath failed for temporaryDirectory") }; return
        }
        let tmpRoot = String(cString: tbuf)
        guard root.hasPrefix(tmpRoot + "/"), root.contains("spz-rtm-") else {
            for n in names { Check.expect(n, false, "safety gate refused fixture root \(root)") }; return
        }
        guard let t = await ScanSession(root: root, excludes: [])?.run(progress: { _ in }) else {
            for n in names { Check.expect(n, false, "fixture scan") }; return
        }
        guard t.path(0) == root else {
            for n in names { Check.expect(n, false, "path-form mismatch engine=\(t.path(0)) fixture=\(root)") }; return
        }
        guard let a = t.find(path: "\(root)/a.bin"), let b = t.find(path: "\(root)/b.bin"), let c = t.find(path: "\(root)/c.bin"), a != 0, b != 0, c != 0 else {
            for n in names { Check.expect(n, false, "fixture find") }; return
        }
        let aURL = d.appendingPathComponent("a.bin")
        let bURL = d.appendingPathComponent("b.bin")
        let cURL = d.appendingPathComponent("c.bin")

        // 1. REAL move, default seams: the file really leaves the fixture, lands in a real .Trash,
        // and the journal records the real trashed URL outside the fixture root. The journal URL is
        // registered for cleanup immediately, whatever the check outcome.
        let m1 = AppModel()
        m1.tree = t
        m1.proposeRemoval(of: a)
        m1.confirmRemoval()
        await m1.removalTask?.value
        if let u = m1.lastRemoved.first?.trashed { trashedLeftovers.append(u) }
        let moved = !fm.fileExists(atPath: aURL.path)
            && m1.lastRemoved.count == 1
            && fm.fileExists(atPath: m1.lastRemoved[0].trashed.path)
            && !m1.lastRemoved[0].trashed.path.hasPrefix(root)
            && m1.lastRemoved[0].trashed.path.contains(".Trash")
        Check.expect("real-trash-move-executes-and-journals", moved,
                     "gone=\(!fm.fileExists(atPath: aURL.path)) journal=\(m1.lastRemoved.count) trashed=\(m1.lastRemoved.first?.trashed.path ?? "nil") msg=\(m1.removalMessage ?? "nil")")

        // 2. REAL undo. The engine commit after the move must settle first or undoRemoval refuses
        // ("still being applied") and the check would fail for the wrong reason.
        let settled1 = await settleSurfaces(m1)
        m1.undoRemoval()
        await m1.removalTask?.value
        Check.expect("real-trash-undo-restores-original",
                     settled1 && fm.fileExists(atPath: aURL.path) && (try? Data(contentsOf: aURL).count) == 1_000 && m1.removalReportKind == .putBack,
                     "settled=\(settled1) restored=\(fm.fileExists(atPath: aURL.path)) kind=\(m1.removalReportKind) msg=\(m1.removalMessage ?? "nil")")

        // 3. REAL identity refusal: b.bin changes on disk after the scan (size grows, so the engine
        // lstat verdict cannot be .same). The refusal must come from the identity verdict itself -
        // its own message - not from any gate, which would leave the same filesystem state.
        try! Data(repeating: 9, count: 7_000).write(to: bURL)
        let m2 = AppModel()
        m2.tree = t
        m2.proposeRemoval(of: b)
        m2.confirmRemoval()
        await m2.removalTask?.value
        Check.expect("real-trash-identity-replaced-refuses-move",
                     fm.fileExists(atPath: bURL.path) && m2.lastRemoved.isEmpty
                        && (m2.removalMessage ?? "").contains("was replaced since the scan")
                        && m2.removalReportKind == .notMoved,
                     "exists=\(fm.fileExists(atPath: bURL.path)) journal=\(m2.lastRemoved.count) kind=\(m2.removalReportKind) msg=\(m2.removalMessage ?? "nil")")

        // 4. REAL restore collision: c.bin really moves, a new file appears at the original path,
        // and the undo must actually hit the collision path - the collision message, the .notMoved
        // kind and the retained journal entry prove the probe ran, not that some gate refused first.
        let m3 = AppModel()
        m3.tree = t
        m3.proposeRemoval(of: c)
        m3.confirmRemoval()
        await m3.removalTask?.value
        if let u = m3.lastRemoved.first?.trashed { trashedLeftovers.append(u) }
        guard m3.lastRemoved.count == 1 else {
            Check.expect("real-trash-restore-collision-keeps-both", false, "setup move failed msg=\(m3.removalMessage ?? "nil")")
            return
        }
        let settled3 = await settleSurfaces(m3)
        let trashedC = m3.lastRemoved[0].trashed
        try! Data(repeating: 4, count: 2_000).write(to: cURL)   // the collision at the original path
        m3.undoRemoval()
        await m3.removalTask?.value
        let collisionKept = settled3
            && fm.fileExists(atPath: cURL.path)
            && (try? Data(contentsOf: cURL).count) == 2_000
            && fm.fileExists(atPath: trashedC.path)
            && (m3.removalMessage ?? "").contains("something already exists at")
            && m3.removalReportKind == .notMoved
            && m3.lastRemoved.count == 1
        Check.expect("real-trash-restore-collision-keeps-both", collisionKept,
                     "settled=\(settled3) originalIntact=\((try? Data(contentsOf: cURL).count) == 2_000) trashedPresent=\(fm.fileExists(atPath: trashedC.path)) journal=\(m3.lastRemoved.count) kind=\(m3.removalReportKind) msg=\(m3.removalMessage ?? "nil")")
    }
}
#endif
