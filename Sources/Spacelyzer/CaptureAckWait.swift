#if SPZ_CI_TESTS
import Foundation

/// CI-only capture handshake wait. Until the runner asks for an external
/// observation (the probe request file exists) the wait blocks exactly as before.
/// While the request file exists the wait services the main run loop in short
/// slices so out-of-process Accessibility requests can be answered, and it checks
/// a live state fingerprint after every slice. Any change is recorded in a drift
/// file the runner rejects; after the request is withdrawn it writes a blocked marker; the fingerprint comes from the live window and model,
/// not from the published state files. Returns true when the ack appeared.
enum CaptureAckWait {
    struct Hooks {
        var exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        var read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
        var write: (String, String) -> Void = { try? $1.write(toFile: $0, atomically: true, encoding: .utf8) }
        var now: () -> Date = { Date() }
        var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        var pump: (TimeInterval) -> Void = { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval($0)) }
    }
    static func wait(step: Int, deadline: Date, fingerprint: () -> String, hooks: Hooks = Hooks()) -> Bool {
        let ack = "/tmp/spz-demo-ack-\(step)", probe = "/tmp/spz-demo-probe-\(step)", drift = "/tmp/spz-demo-drift-\(step)", blocked = "/tmp/spz-demo-blocked-\(step)"
        let baseline = fingerprint()
        var drifted = false, pumped = false, announcedBlocked = false
        var token = ""
        func check() {
            let current = fingerprint()
            if current != baseline, !drifted {
                drifted = true
                hooks.write(drift, "baseline=\(baseline)\ncurrent=\(current)\n")
            }
        }
        while !hooks.exists(ack) && hooks.now() < deadline {
            // One observation cycle per capture step. After the blocked marker is
            // written the wait never pumps again, even if a new request appears.
            if !announcedBlocked, hooks.exists(probe), let requested = hooks.read(probe), !requested.isEmpty {
                token = requested
                pumped = true
                hooks.pump(0.05)
                check()
            } else {
                // Request withdrawn: take one last live comparison, then announce that
                // the main thread is blocked again. The marker carries the request
                // token and the verdict; the runner accepts only "stable:<token>".
                if pumped, !announcedBlocked {
                    check()
                    announcedBlocked = true
                    hooks.write(blocked, (drifted ? "drifted:" : "stable:") + token)
                }
                hooks.sleep(0.05)
            }
        }
        return hooks.exists(ack)
    }
}
#endif
