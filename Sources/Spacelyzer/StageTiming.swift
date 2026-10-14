import Foundation

/// Diagnostic-only stage attribution for outline refreshes. Compiled in but INERT unless the
/// process is launched with SPZ_TIMING=1 and SPZ_TIMING_LOG naming a writable file path.
/// Bar-gated probes run with it OFF; the only cost then is one env-derived static check per mark.
/// Marks are timestamp pairs (start/monotonic uptime ns) with a known-safe context token
/// (cause labels, plan names, row counts - no quotes, no user data). File writes happen on a
/// dedicated serial queue, never inline on the measured path beyond an append under a lock.
enum StageTiming {
    private static let environment = ProcessInfo.processInfo.environment
    static let enabled: Bool = environment["SPZ_TIMING"] == "1" && environment["SPZ_TIMING_LOG"] != nil
    private static let logPath: String = environment["SPZ_TIMING_LOG"] ?? ""
    private static let lock = NSLock()
    private static let writer = DispatchQueue(label: "spz.stage-timing")
    private static var pending: [String] = []

    /// Record one stage mark. `t0` is a DispatchTime.now().uptimeNanoseconds taken at stage start.
    static func mark(_ stage: String, since t0: UInt64, ctx: String) {
        guard enabled else { return }
        let dt = DispatchTime.now().uptimeNanoseconds - t0
        let line = "{\"stage\":\"\(stage)\",\"ms\":\(Double(dt) / 1e6),\"t0\":\(t0),\"ctx\":\"\(ctx)\"}"
        lock.lock(); pending.append(line); lock.unlock()
        writer.async { drain() }
    }

    private static func drain() {
        lock.lock(); let lines = pending; pending.removeAll(); lock.unlock()
        guard !lines.isEmpty else { return }
        let url = URL(fileURLWithPath: logPath)
        let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
