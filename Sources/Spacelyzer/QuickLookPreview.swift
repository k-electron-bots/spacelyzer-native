import Foundation
import Quartz

/// Read-only Quick Look preview for one reviewed item (E4d). Shows exactly one URL in the
/// shared Quick Look panel; showing another item replaces the current one. Previewing reads
/// the file on disk as it is now: it changes nothing and makes no removal safer.
/// UNCOMPILED/UNRUN until a Mac build.
final class QuickLookController: NSObject, QLPreviewPanelDataSource {
    /// The panel seam: production presents through QLPreviewPanel; checks substitute a
    /// recorder. Called synchronously on the calling thread with the exact accepted URL.
    static var present: (URL) -> Void = QuickLookController.presentPanel(_:)

    /// Accepts only an absolute path. Returns false without touching the panel otherwise.
    @discardableResult
    static func show(path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        present(URL(fileURLWithPath: path))
        return true
    }

    private static func presentPanel(_ url: URL) {
        shared.itemURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = shared
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    private static let shared = QuickLookController()
    private var itemURL: URL?

    private override init() {}

    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int { itemURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        // index is always 0: the source reports exactly one item.
        itemURL! as NSURL
    }
}
