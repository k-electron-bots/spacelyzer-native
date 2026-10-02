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
    var filterText = "" { didSet { scheduleFilter() } }
    var filterKind: FileCategory? { didSet { scheduleFilter() } }
    var filterMinMB: Int = 0 { didSet { scheduleFilter() } }
    var filterMaxMB: Int = 0 { didSet { scheduleFilter() } }
    /// Only files modified within the last N days (0 = any time).
    var filterModifiedDays: Int = 0 { didSet { scheduleFilter() } }
    var filterExt = "" { didSet { scheduleFilter() } }
    var activeFilter: FilterResult?
    var outlineSort: OutlineSort = .sizeDescending { didSet { if oldValue != outlineSort { refreshOutline() } } }
    var filterRevision = 0
    /// True from the moment a filter input changes until its result lands. Views may be showing the previous filter.
    var filterPending = false
    var filterMillis: Double = 0
    private var filterTask: Task<Void, Never>?

    var filterIsActive: Bool { !filterText.isEmpty || filterKind != nil || filterMinMB > 0 || filterMaxMB > 0 || filterModifiedDays > 0 || !filterExt.trimmingCharacters(in: .whitespaces).isEmpty }

    func clearFilters() { filterText = ""; filterKind = nil; filterMinMB = 0; filterMaxMB = 0; filterModifiedDays = 0; filterExt = "" }

    /// Filtering runs in Rust off the main thread, debounced; the UI keeps the last result until the new one lands.
    func scheduleFilter() {
        filterTask?.cancel()
        filterPending = true
        guard let tree else { filterPending = false; return }
        let text = filterText, kind = filterKind, minB: UInt64? = filterMinMB > 0 ? UInt64(filterMinMB) * 1_000_000 : nil
        let maxB: UInt64? = filterMaxMB > 0 ? UInt64(filterMaxMB) * 1_000_000 : nil
        let from: Int64? = filterModifiedDays > 0 ? Int64(Date().timeIntervalSince1970) - Int64(filterModifiedDays) * 86_400 : nil
        let ext = filterExt.trimmingCharacters(in: .whitespaces)
        let active = filterIsActive
        filterTask = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            let t0 = DispatchTime.now().uptimeNanoseconds
            let r = active ? tree.applyFilter(text: text, kind: kind, minBytes: minB, maxBytes: maxB, modifiedFrom: from, ext: ext) : nil
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                self.activeFilter = r
                self.filterPending = false
                self.filterMillis = ms
                self.filterRevision += 1
                self.refreshOutline()
                self.refreshDerived()
            }
        }
    }
    /// Largest-files and per-kind lists are computed in Rust off the main thread, never inside a view body.
    var largestIDs: [UInt32] = []
    var kindRows: [KindRow] = []
    private var derivedTask: Task<Void, Never>?
    func refreshDerived() {
        derivedTask?.cancel()
        guard let tree else { largestIDs = []; kindRows = []; return }
        let flt = activeFilter
        derivedTask = Task.detached(priority: .userInitiated) { [weak self] in
            let t0 = Perf.now()
            let ids = tree.largestFiles(200, filter: flt)
            let kinds = tree.categoryTotals(filter: flt).filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }.map { KindRow(category: $0.category, bytes: $0.bytes, items: $0.items) }
            if Task.isCancelled { return }
            Perf.log("derived largest=\(ids.count) kinds=\(kinds.count) filtered=\(flt != nil) rust_ms=\(String(format: "%.2f", Perf.ms(since: t0)))")
            await MainActor.run { self?.largestIDs = ids; self?.kindRows = kinds }
        }
    }
    var outlineRows: [SpzRow] = []
    /// node -> row index, built off the main thread with the rows so selection lookups are O(1).
    var outlineIndex: [UInt32: Int] = [:]
    /// Bumps whenever outlineRows is replaced, so the table reloads exactly once per change.
    var outlineRevision = 0
    var outlineMillis: Double = 0
    private var outlineTask: Task<Void, Never>?

    /// Recompute the flattened outline in Rust off the main thread. Selection and the expanded
    /// set live here, so they survive re-projection.
    func refreshOutline() {
        guard let tree else { outlineRows = []; outlineIndex = [:]; outlineRevision += 1; return }
        let root = displayedRoot, ex = expanded, flt = activeFilter, sort = outlineSort
        outlineTask?.cancel()
        outlineTask = Task.detached(priority: .userInitiated) { [weak self] in
            let t0 = DispatchTime.now().uptimeNanoseconds
            let rows = tree.outlineRows(root: root, expanded: ex, filter: flt, sort: sort)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            var index = [UInt32: Int](minimumCapacity: rows.count)
            for (i, r) in rows.enumerated() { index[r.node] = i }
            if Task.isCancelled { return }
            await MainActor.run { self?.outlineRows = rows; self?.outlineIndex = index; self?.outlineRevision += 1; self?.outlineMillis = ms }
        }
    }

    /// Expand every collapsed ancestor between the displayed root and `id`, so a selection made elsewhere
    /// (treemap, Largest) becomes a visible outline row. No-op when the row is already present or not under the root.
    func revealInOutline(_ id: UInt32) {
        guard let tree, outlineIndex[id] == nil, UInt64(id) < tree.nodeCount else { return }
        var chain: [UInt32] = []
        var cur = tree.info(id).parent
        while let p = cur {
            chain.append(p)
            if p == displayedRoot { break }
            cur = tree.info(p).parent
        }
        guard chain.last == displayedRoot else { return }   // not under the displayed folder
        let before = expanded.count
        for p in chain { expanded.insert(p) }
        if expanded.count != before { refreshOutline() }
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
    /// Seam for the Trash operation so tests can assert it was or wasn't reached without touching any file.
    var trashItem: (URL) throws -> URL = { url in
        var out: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
        return out! as URL
    }
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
                // Node ids are only valid for one tree: drop every id-keyed cache in the same main-actor turn
                // so no view can index the new tree with ids from the old one.
                filterTask?.cancel(); derivedTask?.cancel(); outlineTask?.cancel()
                outlineRows = []; outlineIndex = [:]; outlineRevision += 1; expanded = []; largestIDs = []; kindRows = []; activeFilter = nil
                pendingRemoval = nil
                tree = t
                displayedRoot = 0
                selected = nil
                revision += 1
                scheduleFilter()
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

    /// True when a filter is active and this item is outside it (hidden from every view).
    func isOutsideFilter(_ id: UInt32) -> Bool {
        guard let f = activeFilter else { return false }
        return f.size(id) == 0
    }

    /// Why removal is unavailable right now, or nil when it is allowed.
    func removalBlockedReason(_ id: UInt32) -> String? {
        if filterPending { return "The filter is still updating." }
        if isOutsideFilter(id) { return "This item is outside the current filter. Clear the filter or select it again." }
        return nil
    }

    func proposeRemoval(of id: UInt32) {
        guard id != 0 else { return }
        // A selection the filter has hidden must not be removable from here: clear the filter or reselect first.
        if filterPending { removalMessage = "The filter is still updating, so the list may be out of date. Try again in a moment."; return }
        if isOutsideFilter(id) { removalMessage = "That item is outside the current filter. Clear the filter or select it again to move it to the Trash."; return }
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
        if filterPending { removalMessage = "The filter is still updating, so nothing was moved. Select the item again in a moment."; return }
        if isOutsideFilter(id) { removalMessage = "The filter changed and this item is no longer shown, so nothing was moved. Select it again to remove it."; return }
        let path = tree.path(id)
        if isProtected(path) {
            removalMessage = "\(path) is protected and cannot be removed from here."
            return
        }
        let url = URL(fileURLWithPath: path)
        let size = tree.info(id).size
        do {
            let trashed = try trashItem(url)
            lastRemoved = [RemovedItem(original: url, trashed: trashed, size: size)]
            tree.forget(id)
            if selected == id { selected = nil }
            revision += 1
            refreshOutline()
            refreshDerived()
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


struct KindRow: Identifiable, Sendable {
    var category: FileCategory
    var bytes: UInt64
    var items: UInt64
    var id: FileCategory { category }
}
