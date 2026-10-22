#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import Foundation

// UNCOMPILED and UNRUN until a Mac run. The REAL-Trash-move gate: every other removal check mocks
// the Trash/identity/restore seams, so no real Trash move has ever executed anywhere. This suite
// overrides NOTHING - AppModel's default seams (FileManager.trashItem, the engine lstat identity
// check, FileManager.moveItem restore, the file-exists collision probe) all run for real against a
// disposable fixture the suite creates and deletes. It proves the actual filesystem behavior the
// mocked suites only simulate: a real move lands in the Trash and journals, a real undo puts the
// item back, a post-scan change refuses the real move, and a real collision keeps both files.
// Wiring is proven on Linux by scripts/test-real-trash-checks.py and check-ordering-manifest.py;
// the Swift behavior itself is UNVERIFIED until an approved Mac run executes it.
@MainActor
enum RealTrashMoveChecks {
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
        defer { try? fm.removeItem(at: d) }
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

        // 1. REAL move, default seams: the file really leaves the fixture, lands in the Trash, and
        // the journal records the real trashed URL outside the fixture root.
        let m1 = AppModel()
        m1.tree = t
        m1.proposeRemoval(of: a)
        m1.confirmRemoval()
        await m1.removalTask?.value
        let moved = !fm.fileExists(atPath: aURL.path)
            && m1.lastRemoved.count == 1
            && fm.fileExists(atPath: m1.lastRemoved[0].trashed.path)
            && !m1.lastRemoved[0].trashed.path.hasPrefix(root)
        Check.expect("real-trash-move-executes-and-journals", moved,
                     "gone=\(!fm.fileExists(atPath: aURL.path)) journal=\(m1.lastRemoved.count) trashed=\(m1.lastRemoved.first?.trashed.path ?? "nil") msg=\(m1.removalMessage ?? "nil")")

        // 2. REAL undo, default restore seam: the same file comes back to its original path.
        m1.undoRemoval()
        await m1.removalTask?.value
        Check.expect("real-trash-undo-restores-original",
                     fm.fileExists(atPath: aURL.path) && (try? Data(contentsOf: aURL).count) == 1_000,
                     "restored=\(fm.fileExists(atPath: aURL.path)) msg=\(m1.removalMessage ?? "nil")")

        // 3. REAL identity refusal: b.bin changes on disk after the scan (size grows, so the engine
        // lstat verdict cannot be .same); the real move must be refused and the file untouched.
        try! Data(repeating: 9, count: 7_000).write(to: bURL)
        let m2 = AppModel()
        m2.tree = t
        m2.proposeRemoval(of: b)
        m2.confirmRemoval()
        await m2.removalTask?.value
        Check.expect("real-trash-identity-replaced-refuses-move",
                     fm.fileExists(atPath: bURL.path) && m2.lastRemoved.isEmpty && m2.removalMessage != nil,
                     "exists=\(fm.fileExists(atPath: bURL.path)) journal=\(m2.lastRemoved.count) msg=\(m2.removalMessage ?? "nil")")

        // 4. REAL restore collision: c.bin really moves, a new file appears at the original path,
        // and the undo must report the collision and leave BOTH files alone. The leftover trashed
        // fixture file is then deleted directly - it is this suite's own uniquely-named temp file.
        let m3 = AppModel()
        m3.tree = t
        m3.proposeRemoval(of: c)
        m3.confirmRemoval()
        await m3.removalTask?.value
        guard m3.lastRemoved.count == 1 else {
            Check.expect("real-trash-restore-collision-keeps-both", false, "setup move failed msg=\(m3.removalMessage ?? "nil")")
            return
        }
        let trashedC = m3.lastRemoved[0].trashed
        try! Data(repeating: 4, count: 2_000).write(to: cURL)   // the collision at the original path
        m3.undoRemoval()
        await m3.removalTask?.value
        let collisionKept = fm.fileExists(atPath: cURL.path)
            && (try? Data(contentsOf: cURL).count) == 2_000
            && fm.fileExists(atPath: trashedC.path)
        Check.expect("real-trash-restore-collision-keeps-both", collisionKept,
                     "originalIntact=\((try? Data(contentsOf: cURL).count) == 2_000) trashedPresent=\(fm.fileExists(atPath: trashedC.path)) msg=\(m3.removalMessage ?? "nil")")
        try? fm.removeItem(at: trashedC)
    }
}
#endif
