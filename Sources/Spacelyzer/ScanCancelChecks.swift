#if SPZ_CI_TESTS
import Foundation

// STAGED: Swift UNCOMPILED/UNRUN on Mac. The ci-checks engine parks a per-session worker at
// a pre-first-enumeration walk boundary BEFORE the real cancel check. No forced verdict/result and no
// progress-publication timing premise. Root-only cancellation is not substantial midscan or mounted UI responsiveness coverage. Shipping engine has no hook or CI entry points.
@MainActor enum ScanCancelChecks {
    private static func wait(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
    static func run() async {
        let names = ["scan-cancel-stops-promptly-and-publishes-partial-tree",
                     "scan-cancel-before-progress-returns-promptly",
                     "rescan-after-model-cancel-is-complete"]
        let fm = FileManager.default
        let d = fm.temporaryDirectory.appendingPathComponent("spz-cxl-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: d, withIntermediateDirectories: false)
            for i in 0..<2 {
                let sub = d.appendingPathComponent("d\(i)")
                try fm.createDirectory(at: sub, withIntermediateDirectories: false)
                for j in 0..<20 { try Data([1]).write(to: sub.appendingPathComponent("f\(j).bin"), options: .withoutOverwriting) }
            }
        } catch {
            for n in names { Check.expect(n, false, "fixture creation failed: \(error)") }
            try? fm.removeItem(at: d)
            return
        }
        // 43 nodes exactly: root, two directories, 40 files. Tiny fixture replaces the
        // timing-dependent 150k fixture and its costly creation/deletion.
        let m = AppModel()
        let deadline = DispatchWorkItem {
            let text = "FAIL deterministic cancellation timeout; fixture retained\n"
            FileHandle.standardError.write(Data(text.utf8))
            if let dir = ProcessInfo.processInfo.environment["SPZ_RESULT_DIR"] {
                try? text.write(toFile: dir + "/result.txt", atomically: true, encoding: .utf8)
            }
            exit(2)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 40, execute: deadline)
        var session: ScanSession?
        func execute() async {
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(d.path, &buf) != nil else {
                for n in names { Check.expect(n, false, "fixture realpath failed") }; return
            }
            let root = String(cString: buf)
            var tmp = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(fm.temporaryDirectory.path, &tmp) != nil,
                  root.hasPrefix(String(cString: tmp) + "/"), root.contains("spz-cxl-") else {
                for n in names { Check.expect(n, false, "canonical temp confinement failed") }; return
            }
            m.ciParkNextScanAfterDirs = 1
            m.scan(root)
            let parked = await wait(2) { m.ciScanGateState == 1 }
            guard parked else {
                for n in names { Check.expect(n, false, "worker park not observed; expired/absent is not coverage") }
                m.cancel(); m.ciReleaseScanGate(); _ = await wait(5) { !m.scanning }
                return
            }
            let start = DispatchTime.now().uptimeNanoseconds
            // Actual Stop handler path to the real C ABI cancel flag, then release the worker.
            m.cancel()
            m.ciReleaseScanGate()
            let modelReleasedWithoutExpiry = m.ciScanGateState == 2
            let idle = await wait(5) { !m.scanning }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            Check.expect("scan-cancel-stops-promptly-and-publishes-partial-tree",
                         modelReleasedWithoutExpiry && ms < 5000 && idle && m.error == nil && m.tree?.wasCancelled == true && m.tree?.nodeCount == 1,
                         "pre_first_enumeration=true released_without_expiry=\(modelReleasedWithoutExpiry) parked=\(parked) idle=\(idle) cancelled=\(m.tree?.wasCancelled ?? false) nodes=\(m.tree?.nodeCount ?? 0) invocation_to_model_idle_ms=\(ms); coarse 5s completion bound, not UI dispatch latency")
            guard idle else {
                Check.expect(names[1], false, "not reached: model worker still active")
                Check.expect(names[2], false, "not reached: model worker still active")
                return
            }
            // Same pre-first-enumeration park at the session API. A nil failure never passes.
            session = ScanSession(root: root, excludes: [], parkAfterDirs: 1)
            guard let s = session else {
                Check.expect(names[1], false, "session init failed")
                Check.expect(names[2], false, "not reached: session init failed")
                return
            }
            let sessionParked = await wait(2) { s.ciGateState == 1 }
            let sessionStart = DispatchTime.now().uptimeNanoseconds
            s.cancel(); s.ciReleaseGate()
            let sessionReleasedWithoutExpiry = s.ciGateState == 2
            let t = await s.run(progress: { _ in })  // watchdog bounds a broken real worker
            let sessionMs = Double(DispatchTime.now().uptimeNanoseconds - sessionStart) / 1e6
            Check.expect("scan-cancel-before-progress-returns-promptly",
                         sessionParked && sessionReleasedWithoutExpiry && sessionMs < 5000 && t?.wasCancelled == true && t?.nodeCount == 1,
                         "pre_first_enumeration=true released_without_expiry=\(sessionReleasedWithoutExpiry) invocation_to_session_result_ms=\(sessionMs); coarse 5s completion bound, not UI dispatch latency; parked=\(sessionParked) cancelled=\(t?.wasCancelled ?? false) nodes=\(t?.nodeCount ?? 0)")
            session = nil
            m.scan(root) // unarmed normal session must complete independently
            let done = await wait(5) { !m.scanning }
            Check.expect("rescan-after-model-cancel-is-complete",
                         done && m.error == nil && m.tree?.wasCancelled == false && m.tree?.nodeCount == 43,
                         "done=\(done) nodes=\(m.tree?.nodeCount ?? 0)/43")
        }
        await execute()
        if m.scanning { m.cancel(); m.ciReleaseScanGate(); _ = await wait(5) { !m.scanning } }
        if !m.scanning && session == nil {
            do { try await Task.detached { try fm.removeItem(at: d) }.value }
            catch { Check.note("cancellation fixture cleanup failed: \(error)") }
        } else { Check.note("cancellation fixture retained because worker may be live: \(d.path)") }
        deadline.cancel() // cleanup included in the cap
    }
}
#endif
