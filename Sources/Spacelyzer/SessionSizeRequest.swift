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

    /// Frame height the gate expects: the requested height, limited only by the screen's visible height.
    nonisolated static func targetFrameHeight(requested: Double, visibleHeight: Double) -> Double { min(requested, visibleHeight) }

    /// Frame to ask for directly (AppKit coordinates, origin bottom-left): requested width, target height,
    /// top edge kept when the whole frame still fits the visible area, otherwise moved to fit vertically.
    nonisolated static func plannedFrame(current: CGRect, visible: CGRect, width: Double, height: Double) -> CGRect {
        let h = min(height, Double(visible.height))
        var y = Double(current.maxY) - h
        y = min(max(y, Double(visible.minY)), Double(visible.maxY) - h)
        return CGRect(x: Double(current.minX), y: y, width: width, height: h)
    }

    /// Every geometry value that could explain a height shortfall, in one record.
    static func snapshot(_ w: NSWindow) -> [String: Any] {
        let f = w.frame, r = w.contentRect(forFrameRect: f)
        return [
            "frame": [Double(f.minX), Double(f.minY), Double(f.width), Double(f.height)],
            "contentRectHeight": Double(r.height), "contentLayoutHeight": Double(w.contentLayoutRect.height),
            "chromeFromLayout": Double(f.height - w.contentLayoutRect.height),
            "styleMask": Int(w.styleMask.rawValue), "isZoomed": w.isZoomed,
            "occluded": !w.occlusionState.contains(.visible),
            "contentMinSize": [Double(w.contentMinSize.width), Double(w.contentMinSize.height)],
            "contentMaxSize": [Double(w.contentMaxSize.width), Double(w.contentMaxSize.height)],
            "minSize": [Double(w.minSize.width), Double(w.minSize.height)], "maxSize": [Double(w.maxSize.width), Double(w.maxSize.height)],
            "visibleFrame": [Double(w.screen?.visibleFrame.minX ?? 0), Double(w.screen?.visibleFrame.minY ?? 0), Double(w.screen?.visibleFrame.width ?? 0), Double(w.screen?.visibleFrame.height ?? 0)],
        ]
    }

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
                var attempts: [[String: Any]] = []
                var before: [String: Any] = [:]
                if let window = DemoInput.window, ordinary.count == 1 {
                    let visible = window.screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: dims[0], height: dims[1])
                    before = Self.snapshot(window)
                    let chrome = Double(window.frame.height - window.contentLayoutRect.height)
                    let targetH = Self.targetFrameHeight(requested: dims[1], visibleHeight: Double(visible.height))
                    DemoInput.setContentSizeExact(window, NSSize(width: dims[0], height: targetH - chrome))
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    var step = Self.snapshot(window); step["name"] = "content-size"
                    step["requestedContentHeight"] = targetH - chrome; step["targetH"] = targetH; step["chromeUsed"] = chrome
                    attempts.append(step)
                    // Fallback only when the content-size path left the frame height short: ask for the frame
                    // directly (the gate is on frame height), keeping the top edge unless it would leave the
                    // visible area. Every attempt is reported so a native run shows which path worked.
                    if abs(Double(window.frame.height) - targetH) > 1 {
                        let rect = Self.plannedFrame(current: window.frame, visible: visible, width: dims[0], height: targetH)
                        window.setFrame(rect, display: true)
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        var second = Self.snapshot(window); second["name"] = "set-frame"
                        second["targetH"] = targetH; second["chromeUsed"] = chrome
                        second["plannedFrame"] = [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
                        attempts.append(second)
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                let window = DemoInput.window
                var report: [String: Any] = [
                    "token": String(parts[0]), "pid": Int(pid), "ordinaryWindowCount": ordinary.count,
                    "sheetAttached": window?.attachedSheet != nil,
                    "frameWidth": Double(window?.frame.width ?? 0), "frameHeight": Double(window?.frame.height ?? 0),
                    "visibleHeight": Double(window?.screen?.visibleFrame.height ?? 0),
                    "visibleWidth": Double(window?.screen?.visibleFrame.width ?? 0),
                ]
                report["before"] = before
                report["attempts"] = attempts
                // Late-settle check: a final height that differs from the last attempt's reading means the
                // window moved after the attempt (async SwiftUI/AppKit layout), not that the request failed.
                if let last = attempts.last?["frame"] as? [Double], last.count == 4 {
                    report["lastAttemptFrameHeight"] = last[3]
                    report["lateSettleDelta"] = Double(window?.frame.height ?? 0) - last[3]
                }
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: res), options: .atomic)
                }
            }
        }
    }
}
#endif
