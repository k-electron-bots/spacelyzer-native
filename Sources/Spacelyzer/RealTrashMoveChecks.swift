#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import Foundation

// UNCOMPILED and UNRUN until a Mac run. The REAL-Trash-move gate: every other removal check mocks
// the Trash/identity/restore seams, so no real Trash move has ever executed anywhere. This suite
// overrides NOTHING - AppModel's default seams (FileManager.trashItem, the engine lstat identity
// check, FileManager.moveItem restore, the file-exists collision probe) all run for real against a
// disposable fixture the suite creates and deletes. It proves the actual filesystem behavior the
// mocked suites only simulate: a real move lands in the Trash and journals, a real undo puts the
// item back, a real identity change refuses the move, and a real collision keeps both files.
// Wiring is proven on Linux by scripts/test-real-trash-checks.py and check-ordering-manifest.py,
// and the confinement/premise/predicate/cleanup logic by scripts/test-real-trash-gate.py
// (design-level behavioral checks, not execution of this Swift). The Swift behavior itself is
// UNVERIFIED until an approved Mac run executes it.
@MainActor
enum RealTrashMoveChecks {
    /// One trashed fixture file registered for fail-closed cleanup, with the device, inode and size
    /// it had when the real Trash move journaled it. Ownership is revalidated before any delete, so
    /// a freed pathname reused by an unrelated file is never removed (inode numbers can be recycled,
    /// so the size must match too; the run-unique filenames make any such collision near-impossible).
    private struct TrashedRef { let url: URL; let dev: UInt64; let ino: UInt64; let size: UInt64 }

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

    /// The live device+inode+size of a path, or nil if it does not exist.
    private static func ownership(_ u: URL) -> (dev: UInt64, ino: UInt64, size: UInt64)? {
        var st = stat()
        guard lstat(u.path, &st) == 0 else { return nil }
        return (UInt64(bitPattern: Int64(st.st_dev)), UInt64(st.st_ino), UInt64(bitPattern: st.st_size))
    }

    /// The deferred cleanup may only ever delete THIS suite's own fixture files sitting in a Trash:
    /// a .Trash path whose name is one of the three unique fixture names (allowing the Finder's
    /// "... 2.bin" dedup suffix). Anything else is left alone - never an unrelated file.
    private static func isExpectedFixtureTrashItem(_ u: URL, marker: String) -> Bool {
        let name = u.lastPathComponent
        guard u.path.contains(".Trash"), (name as NSString).pathExtension == "bin" else { return false }
        let stem = (name as NSString).deletingPathExtension.components(separatedBy: " ").first ?? ""
        return ["\(marker)-a", "\(marker)-b", "\(marker)-c"].contains(stem)
    }

    static func run() async {
        let names = ["real-trash-move-executes-and-journals",
                     "real-trash-undo-restores-original",
                     "real-trash-identity-replaced-refuses-move",
                     "real-trash-restore-collision-keeps-both"]
        let fm = FileManager.default
        let marker = "spz-rtm-\(UUID().uuidString)"
        let d = fm.temporaryDirectory.appendingPathComponent(marker)
        try! fm.createDirectory(at: d, withIntermediateDirectories: true)
        // Allocated-byte distinct sizes (see BatchRemovalExecutionChecks: 1_000/5_000/9_000 land in
        // distinct allocation blocks on the runner's APFS). The filenames carry this run's unique
        // marker, so their Trash paths cannot collide with (or be reused by) unrelated user files.
        let aName = "\(marker)-a.bin", bName = "\(marker)-b.bin", cName = "\(marker)-c.bin"
        try! Data(repeating: 1, count: 1_000).write(to: d.appendingPathComponent(aName))
        try! Data(repeating: 2, count: 5_000).write(to: d.appendingPathComponent(bName))
        try! Data(repeating: 3, count: 9_000).write(to: d.appendingPathComponent(cName))
        var trashedLeftovers: [TrashedRef] = []
        defer {
            // Every task was awaited (or settled via settleRemoval) before any exit from this
            // scope, so nothing is in flight here. Remove the fixture, then any of THIS suite's own
            // files left in the Trash (expected only for the collision case or after a mid-suite
            // failure), each revalidated by name AND by the device+inode recorded at move time.
            try? fm.removeItem(at: d)
            for ref in trashedLeftovers where isExpectedFixtureTrashItem(ref.url, marker: marker) {
                if let now = ownership(ref.url), now.dev == ref.dev, now.ino == ref.ino, now.size == ref.size { try? fm.removeItem(at: ref.url) }
            }
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
        guard let a = t.find(path: "\(root)/\(aName)"), let b = t.find(path: "\(root)/\(bName)"), let c = t.find(path: "\(root)/\(cName)"), a != 0, b != 0, c != 0 else {
            for n in names { Check.expect(n, false, "fixture find") }; return
        }
        let aURL = d.appendingPathComponent(aName)
        let bURL = d.appendingPathComponent(bName)
        let cURL = d.appendingPathComponent(cName)

        // 1. REAL move, default seams: the file really leaves the fixture, lands in a real .Trash,
        // and the journal records the real trashed URL outside the fixture root. The journal URL is
        // registered for cleanup immediately, whatever the check outcome.
        let m1 = AppModel()
        m1.tree = t
        m1.proposeRemoval(of: a)
        m1.confirmRemoval()
        await m1.removalTask?.value
        let m1TrashedPath = m1.lastRemoved.first?.trashed.path
        if let u = m1.lastRemoved.first?.trashed, let own = ownership(u) {
            trashedLeftovers.append(TrashedRef(url: u, dev: own.dev, ino: own.ino, size: own.size))
        }
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
        let restored = fm.fileExists(atPath: aURL.path) && (try? Data(contentsOf: aURL).count) == 1_000 && m1.removalReportKind == .putBack
        Check.expect("real-trash-undo-restores-original", settled1 && restored,
                     "settled=\(settled1) restored=\(fm.fileExists(atPath: aURL.path)) kind=\(m1.removalReportKind) msg=\(m1.removalMessage ?? "nil")")
        // The restore put the item back, so its old Trash path is freed: drop the cleanup claim on
        // it rather than risk touching an unrelated file that later reuses the freed pathname.
        if restored, let p = m1TrashedPath { trashedLeftovers.removeAll { $0.url.path == p } }

        // 3. REAL identity refusal. The engine identity verdict is kind/device/INODE ONLY
        // (engine/src/inspect.rs review_scanned: same = kind_ok && dev_eq && ino == live.ino) - a
        // size or content change that keeps the inode is still .same, so an in-place overwrite
        // would let the real move PROCEED. An atomic write (temp file + rename) replaces the inode
        // while the old one still exists, so the verdict must be .replaced. The premise is asserted
        // BEFORE the real move: if the identity did not actually change, the check fails with a
        // clear premise message instead of trashing a fixture file. (The check is headless; the
        // single lstat on the main actor is deliberate - checkIdentity's off-main guidance exists
        // for UI responsiveness.)
        try! Data(repeating: 9, count: 7_000).write(to: bURL, options: .atomic)
        let preVerdict = t.checkIdentity(b)
        guard preVerdict == .replaced else {
            Check.expect("real-trash-identity-replaced-refuses-move", false,
                         "premise failed: atomic replace must read as .replaced, got \(preVerdict); refusing to run the real move")
            Check.expect("real-trash-restore-collision-keeps-both", false, "not reached: identity premise failed")
            return
        }
        let m2 = AppModel()
        m2.tree = t
        m2.proposeRemoval(of: b)
        m2.confirmRemoval()
        await m2.removalTask?.value
        // Wrong-move defense: if the gate ever misbehaves and b.bin IS moved, capture its journal
        // URL for cleanup immediately, then settle the stray engine commit before scope exit.
        if let u = m2.lastRemoved.first?.trashed, let own = ownership(u) {
            trashedLeftovers.append(TrashedRef(url: u, dev: own.dev, ino: own.ino, size: own.size))
        }
        Check.expect("real-trash-identity-replaced-refuses-move",
                     fm.fileExists(atPath: bURL.path) && m2.lastRemoved.isEmpty
                        && (m2.removalMessage ?? "").contains("was replaced since the scan")
                        && m2.removalReportKind == .notMoved,
                     "exists=\(fm.fileExists(atPath: bURL.path)) journal=\(m2.lastRemoved.count) kind=\(m2.removalReportKind) msg=\(m2.removalMessage ?? "nil")")
        _ = await m2.settleRemoval()

        // 4. REAL restore collision: c.bin really moves, a new file appears at the original path,
        // and the undo must actually hit the collision path - the collision message, the .notMoved
        // kind and the retained journal entry prove the probe ran, not that some gate refused first.
        let m3 = AppModel()
        m3.tree = t
        m3.proposeRemoval(of: c)
        m3.confirmRemoval()
        await m3.removalTask?.value
        if let u = m3.lastRemoved.first?.trashed, let own = ownership(u) {
            trashedLeftovers.append(TrashedRef(url: u, dev: own.dev, ino: own.ino, size: own.size))
        }
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
