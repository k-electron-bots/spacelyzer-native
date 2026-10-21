import Foundation
import Quartz

/// Read-only Quick Look preview (E4d single-item; guarded batch-removal epic slice 4 multi-item).
/// Single-item: shows exactly one URL in the shared panel; showing another replaces the current one.
/// Multi-item: the whole selection in outline row order; the panel opens on the focus index and the
/// panel's own arrows cycle within the set. Previewing reads the file on disk as it is now: it
/// changes nothing and makes no removal safer.
/// UNCOMPILED/UNRUN until a Mac build.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource {
    /// The single-item panel seam: production presents through QLPreviewPanel; checks substitute a
    /// recorder. Called synchronously on the calling thread with the exact accepted URL.
    static var present: (URL) -> Void = QuickLookController.presentPanel(_:)

    /// The multi-item panel seam: same rules as `present`, with the URLs in display order and the
    /// index the panel opens on. Checks substitute a recorder.
    static var presentItems: ([URL], Int) -> Void = QuickLookController.presentPanelItems(_:_:)

    /// Accepts only an absolute path. Returns false without touching the panel otherwise.
    @discardableResult
    static func show(path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        present(URL(fileURLWithPath: path))
        return true
    }

    /// Multi-item preview. The list must be non-empty and every path absolute, or nothing is
    /// presented and the panel seam is never touched. An out-of-range focus index clamps to the
    /// nearest valid index. Showing a new set replaces the old one.
    @discardableResult
    static func show(paths: [String], focus: Int) -> Bool {
        guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") }) else { return false }
        presentItems(paths.map { URL(fileURLWithPath: $0) }, min(max(0, focus), paths.count - 1))
        return true
    }

    /// Pure payload builder so checks drive the ordering without a tree or panel: selection member
    /// paths in outline row order + the focus path -> (paths, focus index). Returns nil for an
    /// empty set; a focus path outside the set falls back to the first row.
    static func payload(memberPaths: [String], focusPath: String?) -> (paths: [String], focus: Int)? {
        guard !memberPaths.isEmpty else { return nil }
        return (memberPaths, focusPath.flatMap { memberPaths.firstIndex(of: $0) } ?? 0)
    }

    private static func presentPanel(_ url: URL) {
        presentPanelItems([url], 0)
    }

    private static func presentPanelItems(_ urls: [URL], _ focus: Int) {
        shared.itemURLs = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = shared
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(0, focus), max(0, urls.count - 1))
        panel.makeKeyAndOrderFront(nil)
    }

    private static let shared = QuickLookController()
    private var itemURLs: [URL] = []

    private override init() {}

    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int { itemURLs.count }

    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        // index is always within 0..<count: the source reports exactly itemURLs.count items.
        itemURLs[index] as NSURL
    }
}
