#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import Foundation

// UNCOMPILED and UNRUN until a Mac run. Real-seam scan-cancellation checks: the mounted driver
// covers cancel STATE (cancel-mid-scan-leaves-a-usable-partial-tree, rescan-after-cancel-works)
// with an implicit wait bound, and PerfDriver measures cancel latency informationally with no
// threshold. This suite adds the missing model-level assertions through the REAL paths - the
// ContentView Stop button calls the same model.cancel() and ScanSession.cancel() -> spz_scan_cancel
// - with explicit bounds and exact outcomes: a mid-scan cancel stops promptly and publishes a
// partial tree flagged wasCancelled (never silently a complete one), an immediate cancel returns
// promptly, and a rescan after cancel completes exactly. Wiring is proven on Linux by
// scripts/test-scan-cancel-checks.py and check-ordering-manifest.py, and the predicate/gate logic
// by scripts/test-scan-cancel-gate.py (design-level behavioral checks, not execution of this
// Swift). The Swift behavior itself is UNVERIFIED until an approved Mac run executes it.
@MainActor
enum ScanCancelChecks {
    /// Bounded poll: returns false after the deadline instead of hanging. Scan completion on a
    /// shared runner gets 60 s (the fixture is ~150k entries); a cancel STOP gets 10 s - that
    /// bound is the responsiveness assertion, not a convenience wait.
    private static func wait(_ seconds: Double, _ cond: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cond()
    }

    /// Sparse fixture files (truncate-created holes, no data blocks): enough entries that a full
    /// scan takes seconds, so a cancel issued after the first progress items lands mid-scan with
    /// overwhelming margin on any plausible runner.
    private static func makeSparseFixture(in d: URL, dirs: Int, perDir: Int, size: UInt64) throws {
        let fm = FileManager.default
        for i in 0..<dirs {
            let sub = d.appendingPathComponent("d\(i)")
            try fm.createDirectory(at: sub, withIntermediateDirectories: false)
            for j in 0..<perDir {
                let u = sub.appendingPathComponent("f\(j).bin")
                guard fm.createFile(atPath: u.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                let h = try FileHandle(forWritingTo: u)
                try h.truncate(atOffset: size)
                try h.close()
            }
        }
    }

    static func run() async {
        let names = ["scan-cancel-stops-promptly-and-publishes-partial-tree",
                     "scan-cancel-before-progress-returns-promptly",
                     "rescan-after-model-cancel-is-complete"]
        let fm = FileManager.default
        let marker = "spz-cxl-\(UUID().uuidString)"
        let d = fm.temporaryDirectory.appendingPathComponent(marker)
        try! fm.createDirectory(at: d, withIntermediateDirectories: true)
        // The suite only ever creates and deletes its own temp fixture - nothing touches the Trash.
        defer { try? fm.removeItem(at: d) }
        // Canonicalize with the same syscall as the engine, then a HARD SAFETY GATE: the canonical
        // fixture root must live under the canonical temporary directory with this suite's marker.
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
        guard root.hasPrefix(tmpRoot + "/"), root.contains("spz-cxl-") else {
            for n in names { Check.expect(n, false, "safety gate refused fixture root \(root)") }; return
        }
        do { try makeSparseFixture(in: d, dirs: 300, perDir: 500, size: 4_096) } catch {
            for n in names { Check.expect(n, false, "fixture creation failed: \(error)") }; return
        }

        // Baseline: one full scan of the deterministic fixture. A cancelled baseline means the
        // fixture or engine is broken, so every check fails on its own terms rather than guessing.
        guard let s0 = ScanSession(root: root, excludes: []),
              let full = await s0.run(progress: { _ in }), !full.wasCancelled else {
            for n in names { Check.expect(n, false, "baseline full scan failed or was cancelled") }; return
        }
        let fullCount = full.nodeCount
        guard fullCount > 150_000 else {
            for n in names { Check.expect(n, false, "fixture too small: \(fullCount) nodes") }; return
        }

        // 1. The REAL user path (ContentView Stop -> AppModel.cancel): cancel after real progress.
        // It must stop within the 10 s responsiveness bound and publish a PARTIAL tree, flagged
        // wasCancelled - a complete tree here means the cancel was ignored.
        let m = AppModel()
        m.scan(root)
        let sawProgress = await wait(60) { m.progress.items >= 1_000 || !m.scanning }
        guard sawProgress, m.scanning, m.progress.items >= 1_000 else {
            Check.expect("scan-cancel-stops-promptly-and-publishes-partial-tree", false,
                         "premise failed: scan ended before reaching 1000 items (items=\(m.progress.items) scanning=\(m.scanning)) - fixture too fast to cancel mid-scan")
            Check.expect("scan-cancel-before-progress-returns-promptly", false, "not reached: cancel premise failed")
            Check.expect("rescan-after-model-cancel-is-complete", false, "not reached: cancel premise failed")
            return
        }
        let cancelAt = DispatchTime.now().uptimeNanoseconds
        m.cancel()
        let stopped = await wait(10) { !m.scanning }
        let stopMs = Double(DispatchTime.now().uptimeNanoseconds - cancelAt) / 1_000_000
        Check.expect("scan-cancel-stops-promptly-and-publishes-partial-tree",
                     stopped && stopMs < 10_000 && m.error == nil && m.tree != nil
                        && m.tree!.wasCancelled && m.tree!.nodeCount < fullCount,
                     "stopped=\(stopped) stopMs=\(String(format: "%.1f", stopMs)) nodes=\(m.tree.map { String($0.nodeCount) } ?? "nil")/\(fullCount) cancelled=\(m.tree.map { String($0.wasCancelled) } ?? "nil") error=\(m.error ?? "none")")

        // 2. Immediate cancel at the session level: the sticky flag is set before the first poll,
        // so run() must return promptly and any tree it yields must be flagged cancelled.
        guard let s2 = ScanSession(root: root, excludes: []) else {
            Check.expect("scan-cancel-before-progress-returns-promptly", false, "ScanSession init failed")
            Check.expect("rescan-after-model-cancel-is-complete", false, "not reached: session init failed")
            return
        }
        s2.cancel()
        let t2 = DispatchTime.now().uptimeNanoseconds
        let r2 = await s2.run(progress: { _ in })
        let immMs = Double(DispatchTime.now().uptimeNanoseconds - t2) / 1_000_000
        Check.expect("scan-cancel-before-progress-returns-promptly",
                     immMs < 10_000 && (r2 == nil || r2!.wasCancelled),
                     "immMs=\(String(format: "%.1f", immMs)) tree=\(r2.map { "nodes=\($0.nodeCount) cancelled=\($0.wasCancelled)" } ?? "nil")")

        // 3. A rescan after the cancel is unaffected: it completes with an exact, unflagged tree.
        m.scan(root)
        let done = await wait(60) { !m.scanning }
        Check.expect("rescan-after-model-cancel-is-complete",
                     done && m.error == nil && m.tree != nil && !m.tree!.wasCancelled
                        && m.tree!.nodeCount == fullCount,
                     "done=\(done) nodes=\(m.tree.map { String($0.nodeCount) } ?? "nil")/\(fullCount) cancelled=\(m.tree.map { String($0.wasCancelled) } ?? "nil") error=\(m.error ?? "none")")
    }
}
#endif
