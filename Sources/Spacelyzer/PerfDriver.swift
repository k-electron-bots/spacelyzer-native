#if SPZ_CI_TESTS && SPZ_CI_PERF   // test builds with the perf flag only: never compiled into the shipped app or the default test build
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

/// Pure milestone logic for the full-scan section (testable without AppKit). Run 40249523646: the four bare-predicate milestones
/// (outline rows, outline/derived/layout version) were already true from launch state when the full scan started, so they were
/// "observed" before the engine-returned mark and the driver correctly refused the durations. A milestone now counts only when it
/// DIFFERS from the state captured right before model.scan(root); a milestone whose state was already non-empty/non-nil is NOT
/// silently dropped, it is reported as a NOTE by the driver. A genuine change before the engine-returned mark still ends INCOMPLETE.
struct PerfState: Equatable {
    var rows: Int
    var outline: UInt64?
    var derived: UInt64?
    var layout: UInt64?
}
enum PerfMilestones {
    enum Outcome: Equatable { case after(UInt64), beforeEngine, never }
    /// nil: the milestone cannot be observed by change because its state was already non-empty at start (reported as a NOTE).
    static func observed(_ name: String, state: PerfState, base: PerfState) -> Bool? {
        switch name {
        case "outline_rows_nonempty": return base.rows > 0 ? nil : state.rows > 0
        case "outline_version": return state.outline != base.outline
        case "derived_version": return state.derived != base.derived
        case "layout_version": return state.layout != base.layout
        default: return nil
        }
    }
    static func staleAtStart(_ name: String, base: PerfState) -> Bool {
        switch name {
        case "outline_rows_nonempty": return base.rows > 0
        case "outline_version": return base.outline != nil
        case "derived_version": return base.derived != nil
        case "layout_version": return base.layout != nil
        default: return false
        }
    }
    static func classify(seen: UInt64?, engine: UInt64) -> Outcome {
        guard let t = seen else { return .never }
        return t >= engine ? .after(t - engine) : .beforeEngine
    }
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

        // Keep the cancel evidence on disk even if part B hangs or the process is killed (run 40251234968 lost it).
        try? (lines.joined(separator: "\n") + "\n").write(toFile: perfPath, atomically: true, encoding: .utf8)

        // B. Full scan: engine return, then each publication milestone, each timestamped the first time it is observed.
        marks.clear()
        func perfState() -> PerfState { PerfState(rows: model.outlineRows.count, outline: model.outlineVersion, derived: model.derivedVersion, layout: model.layoutVersion) }
        let base = perfState()
        lines.append("full_scan baseline_before_scan rows=\(base.rows) outline_version=\(base.outline.map(String.init) ?? "nil") derived_version=\(base.derived.map(String.init) ?? "nil") layout_version=\(base.layout.map(String.init) ?? "nil") tree_present=\(model.tree != nil)")
        let s0 = now()
        model.scan(root)
        let milestones: [(String, @MainActor () -> Bool)] = [
            ("tree_published", { !model.scanning && model.tree != nil }),
            ("outline_rows_nonempty", { PerfMilestones.observed("outline_rows_nonempty", state: perfState(), base: base) ?? false }),
            ("outline_version", { PerfMilestones.observed("outline_version", state: perfState(), base: base) ?? false }),
            ("derived_version", { PerfMilestones.observed("derived_version", state: perfState(), base: base) ?? false }),
            ("layout_version", { PerfMilestones.observed("layout_version", state: perfState(), base: base) ?? false }),
        ]
        var seen: [String: UInt64] = [:]
        let fullDeadline = now() + 120_000_000_000   // the cancel leg waits at most 200 s for a result; never outlive it
        let unobservable = Set(milestones.map { $0.0 }.filter { PerfMilestones.staleAtStart($0, base: base) && $0 == "outline_rows_nonempty" })
        // Run 40251234968: a milestone that never changes from its baseline made this loop wait the full 600 s and the driver never wrote a result.
        // Once the engine has returned, wait only a bounded grace (30 s) for the remaining milestones; anything still unobserved is recorded as
        // "never observed" and the run ends INCOMPLETE with the baseline lines as evidence.
        let graceNs: UInt64 = 30_000_000_000
        while now() < fullDeadline && seen.count + unobservable.count < milestones.count {
            if let eng = marks.first("engine-returned"), now() > eng + graceNs { break }
            for (n, cond) in milestones where seen[n] == nil && !unobservable.contains(n) && cond() { seen[n] = now() }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let engine = marks.first("engine-returned")
        let nodes = model.tree?.nodeCount
        lines.append("full_scan nodes=\(nodes.map(String.init) ?? "unknown") progress_items=\(model.progress.items) last_scan_seconds=\(model.lastScanSeconds.map { String(format: "%.2f", $0) } ?? "unknown")")
        if let e = engine {
            lines.append("full_scan start_to_engine_returned_ms=\(ms(s0, e))")
            for (n, _) in milestones {
                if unobservable.contains(n) {
                    lines.append("full_scan NOTE \(n): state was already non-empty before the scan started (stale baseline); not observable by change, no duration recorded")
                    continue
                }
                if PerfMilestones.staleAtStart(n, base: base) { lines.append("full_scan NOTE \(n): had a stale value before the scan; counted only because it changed") }
                switch PerfMilestones.classify(seen: seen[n], engine: e) {
                case .after: lines.append("full_scan engine_returned_to_\(n)_ms=\(ms(e, seen[n]!))")
                case .beforeEngine: problems.append("full_scan: \(n) observed before the engine-returned mark; ordering anomaly, no duration recorded")
                case .never: problems.append("full_scan: milestone \(n) never observed; no duration recorded")
                }
            }
        } else { problems.append("full_scan: engine-returned mark missing; no durations recorded") }

        try? (lines.joined(separator: "\n") + "\n").write(toFile: perfPath, atomically: true, encoding: .utf8)
        let body = problems.isEmpty ? "PERF-COMPLETE\n" : "PERF-INCOMPLETE\n" + problems.joined(separator: "\n") + "\n"
        try? body.write(toFile: resultPath, atomically: true, encoding: .utf8)
        exit(problems.isEmpty ? 0 : 1)
    }
}
#endif
