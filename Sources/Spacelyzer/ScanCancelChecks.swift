#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import Foundation

// UNCOMPILED and UNRUN until a Mac run. Real-seam scan-cancellation checks: the mounted driver
// covers cancel STATE (cancel-mid-scan-leaves-a-usable-partial-tree, rescan-after-cancel-works)
// with an implicit wait bound, and PerfDriver measures cancel latency informationally with no
// threshold. This suite adds the missing model-level assertions through the REAL paths - the
// ContentView Stop button calls the same model.cancel() and ScanSession.cancel() -> spz_scan_cancel
// - with coarse completion bounds: an observed mid-scan cancellation publishes a
// partial tree flagged wasCancelled (never silently a complete one), an immediate cancel returns
// within the coarse bound, and a rescan after cancel completes exactly. A late completed scan
// is an INCONCLUSIVE fixture premise, not evidence of an ignored cancellation. Wiring is proven on Linux by
// scripts/test-scan-cancel-checks.py and check-ordering-manifest.py, and the predicate/gate logic
// by scripts/test-scan-cancel-gate.py (design-level behavioral checks, not execution of this
// Swift). The Swift behavior itself is UNVERIFIED until an approved Mac run executes it.
@MainActor
enum ScanCancelChecks {
    /// Bounded poll: returns false after the deadline instead of hanging. Scan completion on a
    /// shared runner gets 60 s (the fixture is ~150k entries). Cancel invocation to model-idle
    /// publication gets 10 s. This is a coarse completion
    /// bound, not Stop-event dispatch latency or proof of smooth UI responsiveness.
    private static func wait(_ seconds: Double, _ cond: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cond()
    }

    /// Sparse fixture files (truncate-created holes). A completed scan may race the first
    /// progress observation. Fail the premise if no mid-scan window was observed; entry count
    /// alone is not timing proof.
    nonisolated private static func makeSparseFixture(in d: URL, dirs: Int, perDir: Int, size: UInt64) throws {
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

    /// A blocked run() cannot be raced with a structured task group: cancellation does not
    /// interrupt its polling loop. A hard watchdog fails the process instead, without deleting
    /// the fixture under a live scanner. The driver-level 300 s timeout remains unchanged.
    private static func watchdog(_ seconds: Double, phase: String) -> DispatchWorkItem {
        let item = DispatchWorkItem {
            let text = "FAIL ScanCancelChecks timeout: \(phase); fixture retained because scanner may still be live\n"
            FileHandle.standardError.write(Data(text.utf8))
            if let dir = ProcessInfo.processInfo.environment["SPZ_RESULT_DIR"] {
                try? text.write(toFile: dir + "/result.txt", atomically: true, encoding: .utf8)
            }
            exit(2)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }

    static func run() async {
        let names = ["scan-cancel-stops-promptly-and-publishes-partial-tree",
                     "scan-cancel-before-progress-returns-promptly",
                     "rescan-after-model-cancel-is-complete"]
        let fm = FileManager.default
        let marker = "spz-cxl-\(UUID().uuidString)"
        let d = fm.temporaryDirectory.appendingPathComponent(marker)
        do { try fm.createDirectory(at: d, withIntermediateDirectories: false) } catch {
            for n in names { Check.expect(n, false, "fixture mkdir failed: \(error)") }
            return
        }
        let m = AppModel()
        var cleanupAllowed = true
        let totalDeadline = watchdog(120, phase: "whole suite (including fixture creation)")
        // Keep the watchdog armed through asynchronous fixture deletion. No synchronous
        // recursive deletion on the main actor, and no deletion while a worker may be alive.
        func execute() async {
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
            do { try await Task.detached { try makeSparseFixture(in: d, dirs: 300, perDir: 500, size: 4_096) }.value } catch {
                for n in names { Check.expect(n, false, "fixture creation failed: \(error)") }; return
            }

            // Baseline: one full scan of the deterministic fixture. A cancelled baseline means the
            // fixture or engine is broken, so every check fails on its own terms rather than guessing.
            let baselineDeadline = watchdog(60, phase: "baseline scan")
            defer { baselineDeadline.cancel() }
            guard let s0 = ScanSession(root: root, excludes: []),
                  let full = await s0.run(progress: { _ in }), !full.wasCancelled else {
                for n in names { Check.expect(n, false, "baseline full scan failed or was cancelled") }; return
            }
            baselineDeadline.cancel()
            let fullCount = full.nodeCount
            guard fullCount > 150_000 else {
                for n in names { Check.expect(n, false, "fixture too small: \(fullCount) nodes") }; return
            }

            // 1. The REAL user path (ContentView Stop -> AppModel.cancel): cancel after real progress.
            // Published progress and scanning are not a worker rendezvous: a full result can win
            // this race legitimately. Classify that outcome as INCONCLUSIVE fixture coverage,
            // never as a product failure or an ignored cancellation. No retry here.
            m.scan(root)
            let sawProgress = await wait(60) { m.progress.items >= 1_000 || !m.scanning }
            guard sawProgress, m.scanning, m.progress.items >= 1_000 else {
                Check.expect("scan-cancel-stops-promptly-and-publishes-partial-tree", false,
                             "INCONCLUSIVE fixture premise: no live progress window before 1000 items (items=\(m.progress.items) scanning=\(m.scanning)) - fixture too fast to cancel mid-scan")
                Check.expect("scan-cancel-before-progress-returns-promptly", false, "not reached: cancel premise failed")
                Check.expect("rescan-after-model-cancel-is-complete", false, "not reached: cancel premise failed")
                m.cancel()
                cleanupAllowed = await wait(10) { !m.scanning }
                return
            }
            let cancelAt = DispatchTime.now().uptimeNanoseconds
            m.cancel()
            let stopped = await wait(10) { !m.scanning }
            let stopMs = Double(DispatchTime.now().uptimeNanoseconds - cancelAt) / 1_000_000
            let lateCompletion = stopped && m.tree?.nodeCount == fullCount && m.tree?.wasCancelled == false
            Check.expect("scan-cancel-stops-promptly-and-publishes-partial-tree",
                         stopped && stopMs < 10_000 && m.error == nil && m.tree != nil
                            && m.tree!.wasCancelled && m.tree!.nodeCount < fullCount,
                         "classification=\(lateCompletion ? "INCONCLUSIVE late completion; cancellation coverage not established" : "cancel-to-model-idle completion check") stopped=\(stopped) stopMs=\(String(format: "%.1f", stopMs)) nodes=\(m.tree.map { String($0.nodeCount) } ?? "nil")/\(fullCount) cancelled=\(m.tree.map { String($0.wasCancelled) } ?? "nil") error=\(m.error ?? "none")")

            guard stopped else {
                m.cancel()
                cleanupAllowed = await wait(10) { !m.scanning }
                Check.expect("scan-cancel-before-progress-returns-promptly", false, "not reached: prior cancel timed out")
                Check.expect("rescan-after-model-cancel-is-complete", false, "not reached: prior cancel timed out")
                return
            }

            // 2. Cancel immediately after session construction. The worker already started, so
            // a full unflagged tree is an INCONCLUSIVE late-completion premise, not ignored cancel.
            guard let s2 = ScanSession(root: root, excludes: []) else {
                Check.expect("scan-cancel-before-progress-returns-promptly", false, "ScanSession init failed")
                Check.expect("rescan-after-model-cancel-is-complete", false, "not reached: session init failed")
                return
            }
            let immediateDeadline = watchdog(10, phase: "immediate cancel")
            let t2 = DispatchTime.now().uptimeNanoseconds
            s2.cancel()
            let r2 = await s2.run(progress: { _ in })
            immediateDeadline.cancel()
            let immMs = Double(DispatchTime.now().uptimeNanoseconds - t2) / 1_000_000
            Check.expect("scan-cancel-before-progress-returns-promptly",
                         immMs < 10_000 && r2 != nil && r2!.wasCancelled,
                         "classification=\(r2?.wasCancelled == false ? "INCONCLUSIVE worker completed before cancellation" : "coarse completion check") immMs=\(String(format: "%.1f", immMs)) tree=\(r2.map { "nodes=\($0.nodeCount) cancelled=\($0.wasCancelled)" } ?? "nil")")

            // 3. A rescan after the cancel is unaffected: it completes with an exact, unflagged tree.
            m.scan(root)
            let done = await wait(60) { !m.scanning }
            Check.expect("rescan-after-model-cancel-is-complete",
                         done && m.error == nil && m.tree != nil && !m.tree!.wasCancelled
                            && m.tree!.nodeCount == fullCount,
                         "done=\(done) nodes=\(m.tree.map { String($0.nodeCount) } ?? "nil")/\(fullCount) cancelled=\(m.tree.map { String($0.wasCancelled) } ?? "nil") error=\(m.error ?? "none")")
            if !done {
                m.cancel()
                cleanupAllowed = await wait(10) { !m.scanning }
            }
        } // execute
        await execute()
        if m.scanning {
            m.cancel()
            cleanupAllowed = await wait(10) { !m.scanning }
        }
        if cleanupAllowed && !m.scanning {
            do { try await Task.detached { try fm.removeItem(at: d) }.value }
            catch { Check.note("ScanCancelChecks fixture cleanup failed: \(error)") }
        } else { Check.note("ScanCancelChecks retained live-scanner fixture: \(d.path)") }
        totalDeadline.cancel()
    }
}
#endif
