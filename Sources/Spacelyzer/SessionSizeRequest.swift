#if SPZ_CI_TESTS
import AppKit
import Foundation

/// CI-only. Lets the capture runner ask THIS process (same PID, same session) to size its main window
/// through the app's own sizing path, then reports the geometry the window actually has. Accessibility
/// setAXSize is clamped to the screen on the runner (run 40098663789: 1280x800 requested, 992x665 got);
/// the app path lets width overflow and clips only height to the visible frame.
/// Request file /tmp/spz-size-request-<pid>: "<token> <W>x<H>" (frame size). Report file
/// /tmp/spz-size-result-<pid> echoes the token. Inert unless SPZ_SIZE_REQUESTS=1.
@MainActor enum SessionSizeRequest {
    static func start(env: [String: String]) {
        guard env["SPZ_SIZE_REQUESTS"] == "1" else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let req = "/tmp/spz-size-request-\(pid)", res = "/tmp/spz-size-result-\(pid)"
        Task { @MainActor in
            var handled = ""
            while true {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let text = try? String(contentsOfFile: req, encoding: .utf8) else { continue }
                let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
                guard parts.count == 2, String(parts[0]) != handled else { continue }
                let dims = parts[1].split(separator: "x").compactMap { Double($0) }
                guard dims.count == 2, dims[0] >= 600, dims[0] <= 2000, dims[1] >= 400, dims[1] <= 1400 else { continue }
                handled = String(parts[0])
                let ordinary = NSApp.windows.filter { $0.isVisible && !$0.isSheet && !($0 is NSPanel) && $0.canBecomeMain }
                if let window = DemoInput.window, ordinary.count == 1 {
                    let chrome = Double(window.frame.height - window.contentLayoutRect.height)
                    let visibleH = Double(window.screen?.visibleFrame.height ?? CGFloat(dims[1]))
                    DemoInput.setContentSizeExact(window, NSSize(width: dims[0], height: min(dims[1], visibleH) - chrome))
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                let window = DemoInput.window
                let report: [String: Any] = [
                    "token": String(parts[0]), "pid": Int(pid), "ordinaryWindowCount": ordinary.count,
                    "sheetAttached": window?.attachedSheet != nil,
                    "frameWidth": Double(window?.frame.width ?? 0), "frameHeight": Double(window?.frame.height ?? 0),
                    "visibleHeight": Double(window?.screen?.visibleFrame.height ?? 0),
                    "visibleWidth": Double(window?.screen?.visibleFrame.width ?? 0),
                ]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: res), options: .atomic)
                }
            }
        }
    }
}
#endif
