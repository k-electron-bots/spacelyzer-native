import AppKit
import CSpacelyzer
import Foundation
import Observation

enum TreemapColoring: String, CaseIterable, Identifiable {
    case folder = "Folder", kind = "Kind", depth = "Depth"
    var id: String { rawValue }
}

enum TrailingTab: Hashable { case treemap, kinds, largest }

struct RemovedItem { var original: URL; var trashed: URL; var size: UInt64 }

@MainActor @Observable
final class AppModel {
    var tree: Tree?
    var rootPath: String = ""
    var scanning = false
    var progress = ScanSnapshot(items: 0, bytes: 0)
    var elapsed: TimeInterval = 0
    var lastScanSeconds: TimeInterval?
    var error: String?

    var displayedRoot: UInt32 = 0
    var selected: UInt32?
    var expanded: Set<UInt32> = []
    var outlineRows: [SpzRow] = []
    var outlineMillis: Double = 0
    private var outlineTask: Task<Void, Never>?

    /// Recompute the flattened outline in Rust off the main thread. Selection and the expanded
    /// set live here, so they survive re-projection.
    func refreshOutline() {
        guard let tree else { outlineRows = []; return }
        let root = displayedRoot, ex = expanded
        outlineTask?.cancel()
        outlineTask = Task.detached(priority: .userInitiated) { [weak self] in
            let t0 = DispatchTime.now().uptimeNanoseconds
            let rows = tree.outlineRows(root: root, expanded: ex)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            if Task.isCancelled { return }
            await MainActor.run { self?.outlineRows = rows; self?.outlineMillis = ms }
        }
    }

    func toggle(_ id: UInt32) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        refreshOutline()
    }
    var coloring: TreemapColoring = .folder
    var tab: TrailingTab = .treemap
    var revision = 0   // bumps when the tree changes, so views refresh
    var exclusions: [String] = []

    var pendingRemoval: UInt32?
    var lastRemoved: [RemovedItem] = []
    var removalMessage: String?

    private var session: ScanSession?

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Scan"
        if p.runModal() == .OK, let url = p.url { scan(url.path) }
    }

    func scanStartupVolume() { scan("/") }
    func scanHome() { scan(NSHomeDirectory()) }

    func scan(_ path: String) {
        cancel()
        scanning = true
        error = nil
        rootPath = path
        progress = ScanSnapshot(items: 0, bytes: 0)
        let start = Date()
        guard let s = ScanSession(root: path, excludes: exclusions) else {
            error = "Could not start a scan of \(path)"
            scanning = false
            return
        }
        session = s
        Task {
            let t = await s.run { [weak self] snap in
                Task { @MainActor in
                    self?.progress = snap
                    self?.elapsed = Date().timeIntervalSince(start)
                }
            }
            scanning = false
            lastScanSeconds = Date().timeIntervalSince(start)
            session = nil
            if let t {
                tree = t
                displayedRoot = 0
                selected = nil
                revision += 1
                refreshOutline()
            } else {
                error = "The scan failed. Check that the folder exists and you can read it."
            }
        }
    }

    func cancel() { session?.cancel() }

    func drill(into id: UInt32) {
        guard let tree else { return }
        let n = tree.info(id)
        guard n.kind == .directory, n.childCount > 0 else { return }
        displayedRoot = id
        selected = id
        refreshOutline()
    }

    func up() {
        guard let tree, let p = tree.info(displayedRoot).parent else { return }
        displayedRoot = p
        refreshOutline()
    }

    // MARK: Removal (always to the Trash, always after confirmation, always undoable)

    func proposeRemoval(of id: UInt32) {
        guard id != 0 else { return }
        pendingRemoval = id
    }

    /// Paths that must never be removed, whatever the user selects.
    private func isProtected(_ path: String) -> Bool {
        let fixed: Set<String> = ["/", "/System", "/Library", "/Applications", "/Users", "/usr", "/bin", "/sbin", "/private", "/var", "/etc", "/opt", "/cores", "/Volumes", NSHomeDirectory()]
        if fixed.contains(path) { return true }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/bin/") || path.hasPrefix("/sbin/") { return true }
        return false
    }

    func confirmRemoval() {
        guard let tree, let id = pendingRemoval else { return }
        pendingRemoval = nil
        let path = tree.path(id)
        if isProtected(path) {
            removalMessage = "\(path) is protected and cannot be removed from here."
            return
        }
        let url = URL(fileURLWithPath: path)
        let size = tree.info(id).size
        do {
            var out: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &out)
            lastRemoved = [RemovedItem(original: url, trashed: out! as URL, size: size)]
            tree.forget(id)
            if selected == id { selected = nil }
            revision += 1
            refreshOutline()
            removalMessage = "Moved \(url.lastPathComponent) to the Trash."
        } catch {
            removalMessage = "Could not move it to the Trash: \(error.localizedDescription)"
        }
    }

    func undoRemoval() {
        for item in lastRemoved {
            do {
                try FileManager.default.moveItem(at: item.trashed, to: item.original)
                removalMessage = "Put \(item.original.lastPathComponent) back. Rescan to refresh sizes."
            } catch {
                removalMessage = "Could not put it back: \(error.localizedDescription)"
            }
        }
        lastRemoved = []
    }

    func reveal(_ id: UInt32) {
        guard let tree else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tree.path(id))])
    }
}

func formatBytes(_ b: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
}
