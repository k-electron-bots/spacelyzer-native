#if SPZ_CI_TESTS   // test/development builds only: never compiled into the shipped app
import Foundation

/// Optional measurement mode (SPZ_CHECKS=perf). Drives the real AppModel scan and cancel paths in the real window and
/// writes timestamps. It asserts nothing about speed: no threshold exists here, and a missing milestone makes the run
/// INCOMPLETE (nonzero exit) instead of printing a duration. Numbers come from whatever machine runs it (a shared runner
/// is ballpark only) and the item count is whatever the chosen root actually contains; it is reported, never assumed.
final class PerfMarks: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [(name: String, ns: UInt64)] = []
    func add(_ name: String) { lock.lock(); rows.append((name, DispatchTime.now().uptimeNanoseconds)); lock.unlock() }
    func first(_ name: String) -> UInt64? { lock.lock(); defer { lock.unlock() }; return rows.first { $0.name == name }?.ns }
    func clear() { lock.lock(); rows.removeAll(); lock.unlock() }
}

@MainActor enum PerfDriver {
    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func ms(_ a: UInt64, _ b: UInt64) -> String { b >= a ? String(format: "%.1f", Double(b - a) / 1_000_000) : "negative(\(Int64(b) - Int64(a))ns)" }

    static func run(model: AppModel, env: [String: String]) async -> Never {
        let fm = FileManager.default
        guard let dir = env["SPZ_RESULT_DIR"], dir.hasPrefix("/"), (try? fm.contentsOfDirectory(atPath: dir))?.isEmpty == true else {
            FileHandle.standardError.write(Data("FAIL SPZ_RESULT_DIR missing, relative, or not an empty directory\n".utf8)); exit(3)
        }
        let perfPath = dir + "/perf.txt", resultPath = dir + "/result.txt"
        guard let root = env["SPZ_PERF_ROOT"], root.hasPrefix("/"), fm.fileExists(atPath: root) else {
            try? "PERF-INCOMPLETE\nSPZ_PERF_ROOT missing, relative, or not found\n".write(toFile: resultPath, atomically: true, encoding: .utf8); exit(3)
        }
        let cancelAt = UInt64(env["SPZ_PERF_CANCEL_AT"] ?? "") ?? 100_000
        let cancelRuns = max(1, Int(env["SPZ_PERF_CANCEL_RUNS"] ?? "") ?? 3)
        DispatchQueue.global().asyncAfter(deadline: .now() + 900) {
            try? "PERF-INCOMPLETE\ntimeout: driver did not finish within 900 s\n".write(toFile: resultPath, atomically: true, encoding: .utf8); exit(2)
        }
        var lines: [String] = []
        var problems: [String] = []
        lines.append("scope: informational timings from one machine; no threshold, budget or pass criterion; not the real-machine gate")
        lines.append("root=\(root) cancel_at_items=\(cancelAt) cancel_runs=\(cancelRuns)")
        let marks = PerfMarks()
        model.beforePublish = { name, _, _ in if name == "scan-completion" { marks.add("engine-returned") } }

        func waitIdle() async -> Bool {
            let deadline = now() + 120_000_000_000
            while model.scanning { if now() > deadline { return false }; try? await Task.sleep(nanoseconds: 2_000_000) }
            return true
        }
        if !(await waitIdle()) { problems.append("model was scanning before the driver started") }

        // A. Cancel: three separate times. cancel_call = the call returning; engine_returned = the scan task saw the
        // engine finish (polled by the app at 100 ms, so this includes up to that interval); scanning_false = the
        // main-actor flag the Stop button state follows, observed by a 2 ms poll.
        for i in 1...cancelRuns {
            marks.clear()
            model.scan(root)
            var reached = false
            let startDeadline = now() + 300_000_000_000
            while now() < startDeadline {
                if model.progress.items >= cancelAt { reached = true; break }
                if !model.scanning { break }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            if !reached {
                problems.append("cancel[\(i)]: scan did not reach \(cancelAt) items before it ended or timed out (items=\(model.progress.items)); no duration recorded")
                _ = await waitIdle(); continue
            }
            let itemsAtCancel = model.progress.items
            let t0 = now(); model.cancel(); let t1 = now()
            var tIdle: UInt64?
            let idleDeadline = now() + 120_000_000_000
            while now() < idleDeadline { if !model.scanning { tIdle = now(); break }; try? await Task.sleep(nanoseconds: 2_000_000) }
            let tEngine = marks.first("engine-returned")
            guard let te = tEngine, let ti = tIdle, te >= t0 else {
                problems.append("cancel[\(i)]: missing milestone (engine_returned=\(tEngine != nil && tEngine! >= t0), scanning_false=\(tIdle != nil)); no duration recorded")
                _ = await waitIdle(); continue
            }
            lines.append("cancel[\(i)] items_at_cancel=\(itemsAtCancel) cancel_call_ms=\(ms(t0, t1)) cancel_to_engine_returned_ms=\(ms(t0, te)) cancel_to_scanning_false_ms=\(ms(t0, ti)) tree_present_after_cancel=\(model.tree != nil) error=\(model.error ?? "none")")
        }

        // B. Full scan: engine return, then each publication milestone, each timestamped the first time it is observed.
        marks.clear()
        let s0 = now()
        model.scan(root)
        let milestones: [(String, @MainActor () -> Bool)] = [
            ("tree_published", { !model.scanning && model.tree != nil }),
            ("outline_rows_nonempty", { !model.outlineRows.isEmpty }),
            ("outline_version", { model.outlineVersion != nil }),
            ("derived_version", { model.derivedVersion != nil }),
            ("layout_version", { model.layoutVersion != nil }),
        ]
        var seen: [String: UInt64] = [:]
        let fullDeadline = now() + 600_000_000_000
        while now() < fullDeadline && seen.count < milestones.count {
            for (n, cond) in milestones where seen[n] == nil && cond() { seen[n] = now() }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let engine = marks.first("engine-returned")
        let nodes = model.tree?.nodeCount
        lines.append("full_scan nodes=\(nodes.map(String.init) ?? "unknown") progress_items=\(model.progress.items) last_scan_seconds=\(model.lastScanSeconds.map { String(format: "%.2f", $0) } ?? "unknown")")
        if let e = engine {
            lines.append("full_scan start_to_engine_returned_ms=\(ms(s0, e))")
            for (n, _) in milestones {
                if let t = seen[n] {
                    if t >= e { lines.append("full_scan engine_returned_to_\(n)_ms=\(ms(e, t))") }
                    else { problems.append("full_scan: \(n) observed before the engine-returned mark; ordering anomaly, no duration recorded") }
                } else { problems.append("full_scan: milestone \(n) never observed; no duration recorded") }
            }
        } else { problems.append("full_scan: engine-returned mark missing; no durations recorded") }

        try? (lines.joined(separator: "\n") + "\n").write(toFile: perfPath, atomically: true, encoding: .utf8)
        let body = problems.isEmpty ? "PERF-COMPLETE\n" : "PERF-INCOMPLETE\n" + problems.joined(separator: "\n") + "\n"
        try? body.write(toFile: resultPath, atomically: true, encoding: .utf8)
        exit(problems.isEmpty ? 0 : 1)
    }
}
#endif
