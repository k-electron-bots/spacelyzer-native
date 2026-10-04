import AppKit
import CSpacelyzer
import Foundation
import Observation

enum TreemapColoring: String, CaseIterable, Identifiable {
    case folder = "Folder", kind = "Kind", depth = "Depth"
    var id: String { rawValue }
}

enum TrailingTab: Hashable { case treemap, kinds, largest, folders }

struct RemovedItem { var original: URL; var trashed: URL; var size: UInt64 }

@MainActor @Observable
final class AppModel {
    /// CI-only contrast branch injection. Product cells ignore it unless SPZ_DEMO is enabled.
    var demoIncreaseContrast: Bool?
    /// Presentation-only CI overrides, ignored outside SPZ_DEMO/Perf. Never alter tree accounting.
    var demoFooterUnreadable: Int?
    var demoFooterPartial: Bool?
    @ObservationIgnored weak var outlineKeyView: NSTableView?
    @ObservationIgnored weak var nameFilterKeyView: NSTextField?
    /// Explicit bridge across the AppKit outline and SwiftUI control hosting boundary.
    func connectOutlineFocusLoop() {
        guard let table = outlineKeyView, let field = nameFilterKeyView,
              table.window != nil, table.window === field.window else { return }
        if table.nextKeyView !== field {
            // Preserve the existing forward chain beyond the filter, without making a two-node cycle.
            if field.nextKeyView == nil, let successor = table.nextKeyView, successor !== table { field.nextKeyView = successor }
            table.nextKeyView = field
        }
    }
    enum BoundaryFocusResult: Equatable {
        case moved, unavailable, restoredUnexpectedLanding, restoreFailed
        var consumesCommand: Bool { self == .moved || self == .restoreFailed }
    }
    /// Explicit product boundary, not a repaired native key-view graph.
    func focusNameFromOutline(_ source: NSView, modifiers: NSEvent.ModifierFlags) -> BoundaryFocusResult {
        guard modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
              source === outlineKeyView, let field = nameFilterKeyView else { return .unavailable }
        return focusBoundary(from: source, to: field)
    }
    func focusOutlineFromName(_ source: NSView, editor: NSTextView, modifiers: NSEvent.ModifierFlags) -> BoundaryFocusResult {
        guard modifiers.intersection([.command, .control, .option]).isEmpty,
              source === nameFilterKeyView, editor.delegate === source,
              source.window?.firstResponder === editor,
              !editor.hasMarkedText(), let table = outlineKeyView else { return .unavailable }
        return focusBoundary(from: source, to: table)
    }
    private func focusBoundary(from source: NSView, to target: NSView) -> BoundaryFocusResult {
        guard let window = source.window, window === target.window,
              window.isKeyWindow, NSApp.isActive, window.isVisible,
              !source.isHiddenOrHasHiddenAncestor, (source as? NSControl)?.isEnabled != false,
              !target.isHiddenOrHasHiddenAncestor, target.acceptsFirstResponder,
              (target as? NSControl)?.isEnabled != false else { return .unavailable }
        let previous = window.firstResponder
        guard previous === source || (previous as? NSTextView)?.delegate === source else { return .unavailable }
        let accepted = window.makeFirstResponder(target)
        if !accepted && window.firstResponder === previous { return .unavailable }
        let actual = window.firstResponder
        let reached = actual === target || (actual as? NSTextView)?.delegate === target
        if accepted && reached {
            if Perf.on { Perf.log("native-tab explicit-boundary reached=true") }
            return .moved
        }
        let restored = window.makeFirstResponder(previous) && window.firstResponder === previous
        if Perf.on { Perf.log("native-tab unexpected-landing restored=\(restored) responder=\(String(describing: window.firstResponder))") }
        // Do not run native fallback from a wrong landing when restoration failed.
        return restored ? .restoredUnexpectedLanding : .restoreFailed
    }
    var tree: Tree?
    var rootPath: String = ""
    var scanning = false
    var progress = ScanSnapshot(items: 0, bytes: 0)
    var elapsed: TimeInterval = 0
    var lastScanSeconds: TimeInterval?
    var error: String?

    var displayedRoot: UInt32 = 0
    /// Bumped on every real selection change (table or model). It is an input of the outline table so SwiftUI cannot skip a table sync when
    /// coalesced changes end on the value last rendered while the table sits elsewhere. A hypothesis-driven remedy, see the CI selection variant.
    var selectionRevision = 0
    var selected: UInt32? { didSet { if selected != oldValue { selectionRevision &+= 1; retryDone("node") } } }   // a retry for the old selection must not outlive it
    var expanded: Set<UInt32> = []
    private var editorOrigin = false
    var externalFilterTextRevision: UInt64 = 0
    var filterResetRevision: UInt64 = 0
    @ObservationIgnored var nameEditorUpdateCount: UInt64 = 0
    @ObservationIgnored var nameEditorConsumedReset: UInt64 = 0
    var nameEditorRefreshRevision: UInt64 = 0
    var filterText = "" { didSet {
        if !editorOrigin && oldValue != filterText { externalFilterTextRevision &+= 1 }
        scheduleFilter()
    } }
    func setFilterTextFromEditor(_ text: String) {
        editorOrigin = true
        filterText = text
        editorOrigin = false
    }
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
    private var filterGeneration: UInt64 = 0
    private var outlineGeneration: UInt64 = 0
    private var derivedGeneration: UInt64 = 0
    private var scanGeneration: UInt64 = 0
    /// Test seam called after detached computation, before the main-actor publication gate.
    var afterPublish: (@Sendable (String, UInt64, UUID) async -> Void)?
    var beforePublish: (@Sendable (String, UInt64, UUID) async -> Void)?

    var filterIsActive: Bool { !filterText.isEmpty || filterKind != nil || filterMinMB > 0 || filterMaxMB > 0 || filterModifiedDays > 0 || !filterExt.trimmingCharacters(in: .whitespaces).isEmpty }

    func clearFilters() { filterResetRevision &+= 1; filterText = ""; filterKind = nil; filterMinMB = 0; filterMaxMB = 0; filterModifiedDays = 0; filterExt = "" }

    /// Filtering runs in Rust off the main thread, debounced; the UI keeps the last result until the new one lands.
    func scheduleFilter(immediate: Bool = false) {
        if !immediate { retryDone("filter") }
        filterTask?.cancel()
        filterGeneration &+= 1
        let generation = filterGeneration, barrier = beforePublish, completed = afterPublish
        filterPending = true
        guard let tree else { filterPending = false; return }
        let text = filterText, kind = filterKind, minB: UInt64? = filterMinMB > 0 ? UInt64(filterMinMB) * 1_000_000 : nil
        let maxB: UInt64? = filterMaxMB > 0 ? UInt64(filterMaxMB) * 1_000_000 : nil
        let from: Int64? = filterModifiedDays > 0 ? Int64(Date().timeIntervalSince1970) - Int64(filterModifiedDays) * 86_400 : nil
        let ext = filterExt.trimmingCharacters(in: .whitespaces)
        let active = filterIsActive
        filterTask = Task.detached(priority: .userInitiated) { [weak self] in
            if !immediate { try? await Task.sleep(nanoseconds: 150_000_000) }
            if Task.isCancelled { return }
            let t0 = DispatchTime.now().uptimeNanoseconds
            var r: FilterResult? = nil
            var failure: EngineStatus? = nil
            if active {
                switch tree.applyFilterChecked(text: text, kind: kind, minBytes: minB, maxBytes: maxB, modifiedFrom: from, ext: ext) {
                case .success(let f): r = f
                case .failure(let st): failure = st
                }
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            if Task.isCancelled { return }
            if let failure {
                // BUSY (admission) or any other status: keep the previous result, never publish an empty one.
                await MainActor.run {
                    guard let self, self.filterGeneration == generation, self.tree === tree else { return }
                    if failure == .busy {
                        // Pending stays true (visible), retries are bounded and keyed; the retry re-reads the current filter inputs.
                        self.retryBusy("filter", inputs: self.filterInputKey) { [weak self] in self?.scheduleFilter(immediate: true) }
                    } else {
                        self.filterPending = false
                        self.markOutOfDate("The filter could not run (\(failure)). The list may be out of date. Rescan, or try again.")
                    }
                }
                return
            }
            let publication = UUID()
            let rFinal = r   // frozen copy: the main-actor closure must not capture the mutable var
            await barrier?("filter", generation, publication)
            await MainActor.run {
                guard let self, !Task.isCancelled, self.filterGeneration == generation, self.tree === tree,
                      (rFinal == nil || rFinal!.version == tree.version) else {
                    // computed on a table that a commit has since replaced: a newer filter run is queued by that commit
                    if let self, self.filterGeneration == generation, self.tree === tree { self.scheduleFilter(immediate: true) }
                    return
                }
                if self.enginePoisoned { self.markPoisoned(); return }   // a caught panic makes this publication untrustworthy
                self.retryDone("filter")
                self.acceptedFilterVersions.append(rFinal?.version ?? 0); if self.acceptedFilterVersions.count > 64 { self.acceptedFilterVersions.removeFirst() }
                self.activeFilter = rFinal
                self.filterPending = false
                self.filterMillis = ms
                self.filterRevision += 1
                self.refreshOutline()
                self.refreshDerived()
            }
            await completed?("filter", generation, publication)
        }
    }
    /// Largest-files and per-kind lists are computed in Rust off the main thread, never inside a view body.
    var largestIDs: [UInt32] = []
    /// Largest folders (Folders tab). Loaded only while that tab is shown, from one engine capture. Rows exist ONLY in `.ready`; every other
    /// state has no rows, so nothing old can be shown or selected while a load is pending, failed, or after a change.
    enum FolderLoad: Equatable { case idle, loading, ready, failed(String) }
    var folderLoad: FolderLoad = .idle
    var folderIDs: [UInt32] = []
    var folderSizes: [UInt64] = []
    var folderVersion: UInt64?
    @ObservationIgnored var folderTask: Task<Void, Never>?
    @ObservationIgnored private(set) var folderGeneration: UInt64 = 0
    /// Test seam: how the list is read. Production reads the engine.
    @ObservationIgnored var folderLoader: @Sendable (Tree, Int) async -> Result<FolderSnapshot, EngineStatus> = { t, n in t.largestFolders(count: n) }
    static let folderCount = 200
    static let folderMaxAttempts = 3
    /// Result words for the CSV export. Separate from `removalMessage`, which belongs to Trash (and its Undo button).
    var exportMessage: String?
    @ObservationIgnored var exportTask: Task<Void, Never>?
    /// Last export outcome, kept for tests and logs.
    @ObservationIgnored var lastExportOutcome: LargestExport.Outcome?
    /// Sizes for largestIDs, same engine capture (the Largest list never reads sizes live).
    var largestSizes: [UInt64] = []
    var kindRows: [KindRow] = []
    private var derivedTask: Task<Void, Never>?
    func refreshDerived() {
        derivedTask?.cancel()
        derivedGeneration &+= 1
        let generation = derivedGeneration, barrier = beforePublish, completed = afterPublish
        guard let tree else { largestIDs = []; largestSizes = []; kindRows = []; return }
        let flt = activeFilter
        derivedTask = Task.detached(priority: .userInitiated) { [weak self] in
            let t0 = Perf.now()
            let result = tree.derivedSnapshot(filter: flt, count: 200)
            if Task.isCancelled { return }
            guard case .success(let snap) = result else {
                await MainActor.run {
                    guard let self, self.derivedGeneration == generation, self.tree === tree else { return }
                    self.handleReadFailure(result.failureStatus, key: "derived", inputs: self.derivedInputKey) { [weak self] in self?.refreshDerived() }
                }
                return
            }
            Perf.log("derived largest=\(snap.ids.count) kinds=\(snap.kinds.count) filtered=\(flt != nil) rust_ms=\(String(format: "%.2f", Perf.ms(since: t0)))")
            let publication = UUID()
            await barrier?("derived", generation, publication)
            await MainActor.run {
                // Full key: tree identity, generation, and the table version the data was read at (the engine's stamp).
                guard let self, !Task.isCancelled, self.derivedGeneration == generation, self.tree === tree else { return }
                // The table moved while this read ran: the result is dropped, but never silently. Bounded keyed retry (ends in the explicit out-of-date state).
                if snap.version != tree.version { self.retryBusy("derived", inputs: self.derivedInputKey) { [weak self] in self?.refreshDerived() }; return }
                guard flt == nil || flt!.version == snap.version else { return }
                if self.enginePoisoned { self.markPoisoned(); return }   // a caught panic makes this publication untrustworthy
                self.retryDone("derived")
                self.derivedVersion = snap.version
                self.largestIDs = snap.ids; self.largestSizes = snap.sizes
                self.kindRows = snap.kinds.filter { $0.items > 0 }.sorted { $0.bytes > $1.bytes }.map { KindRow(category: $0.category, bytes: $0.bytes, items: $0.items) }
                self.surfaceCheck()
            }
            await completed?("derived", generation, publication)
        }
    }
    var outlineRows: [SpzRow] = []
    /// Node details for each row, same index and same table version as outlineRows.
    var outlineInfos: [NodeInfo] = []
    /// Size shown per row (filter size or node size), from the same snapshot as the rows. Cells never read the filter live.
    var outlineShown: [UInt64] = []
    var outlineRootSize: UInt64 = 0
    /// nil until an outline has been published for the current tree (the footer shows a placeholder, never an old total).
    var publishedTotalBytes: UInt64?
    /// Table versions of each published surface. Actions unlock only when every live surface is at the required version.
    var outlineVersion: UInt64?
    var derivedVersion: UInt64?
    var layoutVersion: UInt64?
    /// Bumped to ask the treemap view to relayout (bounded BUSY retry); the view observes it, no escaping view copy.
    var layoutRetryToken = 0
    /// Versions of filter results that were accepted for publication (recent 64). Lets tests prove an old result was never accepted.
    var acceptedFilterVersions: [UInt64] = []
    /// node -> row index, built off the main thread with the rows so selection lookups are O(1).
    var outlineIndex: [UInt32: Int] = [:]
    /// Bumps whenever outlineRows is replaced, so the table reloads exactly once per change.
    var outlineRevision = 0
    var outlineMillis: Double = 0
    private var outlineTask: Task<Void, Never>?

    /// Recompute the flattened outline in Rust off the main thread. Selection and the expanded
    /// set live here, so they survive re-projection.
    func refreshOutline() {
        outlineTask?.cancel()
        outlineGeneration &+= 1
        let generation = outlineGeneration, barrier = beforePublish, completed = afterPublish
        guard let tree else { outlineRows = []; outlineInfos = []; outlineShown = []; outlineIndex = [:]; outlineRevision += 1; outlineRootSize = 0; publishedTotalBytes = nil; return }
        let root = displayedRoot, ex = expanded, flt = activeFilter, sort = outlineSort
        outlineTask?.cancel()
        outlineTask = Task.detached(priority: .userInitiated) { [weak self] in
            let t0 = DispatchTime.now().uptimeNanoseconds
            let result = tree.outlineSnapshot(root: root, expanded: ex, filter: flt, sort: sort)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            if Task.isCancelled { return }
            guard case .success(let snap) = result else {
                await MainActor.run {
                    guard let self, self.outlineGeneration == generation, self.tree === tree else { return }
                    self.handleReadFailure(result.failureStatus, key: "outline", inputs: self.outlineInputKey) { [weak self] in self?.refreshOutline() }
                }
                return
            }
            var index = [UInt32: Int](minimumCapacity: snap.rows.count)
            for (i, r) in snap.rows.enumerated() { index[r.node] = i }
            let publication = UUID()
            await barrier?("outline", generation, publication)
            await MainActor.run {
                // Full key: tree identity, generation, table version of the read, and the filter's own version.
                guard let self, !Task.isCancelled, self.outlineGeneration == generation, self.tree === tree, snap.version == tree.version, flt == nil || flt!.version == snap.version else { return }
                if self.enginePoisoned { self.markPoisoned(); return }   // a caught panic makes this publication untrustworthy
                self.retryDone("outline")
                // Rows, per-row details, root size and total are published in ONE main-actor turn from ONE table version,
                // so cells never mix rows from one version with sizes from another.
                self.outlineRows = snap.rows; self.outlineInfos = snap.infos; self.outlineShown = snap.shown; self.outlineRootSize = snap.rootSize
                self.publishedTotalBytes = snap.totalBytes; self.outlineVersion = snap.version
                self.outlineIndex = index; self.outlineRevision += 1; self.outlineMillis = ms
                self.surfaceCheck()
            }
            await completed?("outline", generation, publication)
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
    var tab: TrailingTab = .treemap { didSet { surfaceCheck() } }
    var revision = 0 { didSet { invalidateFolders() } }   // bumps when the tree changes, so views refresh; the Folders rows are dropped at once
    var exclusions: [String] = []

    var pendingRemoval: UInt32?
    /// Seam for the Trash operation so tests can assert it was or wasn't reached without touching any file.
    var trashItem: (URL) throws -> URL = { url in
        var out: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
        return out! as URL
    }
    var lastRemoved: [RemovedItem] = []
    /// True while a Trash move or undo runs off the main actor; repeat requests are refused meanwhile.
    var removalInFlight = false
    var removalTask: Task<Void, Never>?
    var removalMessage: String?

    // MARK: coherence state (filesystem vs engine numbers)
    /// Counts every filesystem change this app made (successful Trash move, successful undo). A scan that started
    /// before a change and finishes after it cannot be trusted to include it.
    var fsEpoch = 0
    /// Reserved BEFORE the Trash move is attempted, cleared when its engine commit has been published or has failed.
    var mutationPending = false
    /// Removals whose filesystem move finished but whose engine commit has not been published yet.
    var commitsInFlight = 0
    /// The on-screen numbers may not match the disk. Persistent until a scan that provably started after the last change lands.
    var viewOutOfDate = false
    var outOfDateReason: String?
    /// Table version every surface (outline, derived lists, and the layout while the treemap tab is shown) must reach after
    /// a commit before rows can be trusted again. nil when no commit is waiting on surfaces.
    var requiredVersion: UInt64?
    /// Rows on screen belong to the previous publication, or a change is in flight: navigation AND removal are paused.
    var rowsPending: Bool { mutationPending || commitsInFlight > 0 || requiredVersion != nil }
    /// Removal and undo need fresh numbers as well: also blocked while the view is out of date (until a rescan).
    /// Panic baseline for the loaded tree, taken when a scan completes without any caught panic. Any later change is sticky
    /// (never re-adopted) until the next fully successful rescan or a restart.
    @ObservationIgnored var panicBaseline: UInt64 = EnginePanics.count
    /// Injectable so tests can drive the counter; production reads the engine's sticky counter.
    @ObservationIgnored var panicCounter: () -> UInt64 = { EnginePanics.count }
    /// Observable latch set the first time a publication or action sees the counter move; views re-render on it.
    var poisoned = false
    var enginePoisoned: Bool { poisoned || panicCounter() != panicBaseline }
    var destructiveBlocked: Bool { rowsPending || viewOutOfDate || enginePoisoned }
    /// Drill and reveal act on shown rows. An out-of-date but self-consistent old tree may still be navigated.
    var navigationBlocked: Bool { rowsPending || enginePoisoned }
    var coherenceNotice: String? {
        if rowsPending { return "Updating after a change. Opening folders and removing items are paused for a moment." }
        if enginePoisoned { return "The engine reported an internal error, so numbers on screen may be wrong. Removal is disabled until you rescan." }
        if viewOutOfDate { return (outOfDateReason ?? "The numbers on screen may be out of date.") + " Removal is disabled until you rescan." }
        return nil
    }
    /// Idle observability: a bounded 1 s check while a tree is loaded, so a panic caught outside any publication still
    /// reaches the UI. Cancelled on tree replace and deinit; interval is a MainActor wake, not a tight poll.
    @ObservationIgnored private var poisonWatch: Task<Void, Never>?
    func startPoisonWatch() {
        poisonWatch?.cancel()
        poisonWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.tree != nil else { return }
                if !self.poisoned && self.enginePoisoned { self.markPoisoned() }
            }
        }
    }
    func markPoisoned() { poisoned = true; filterPending = false; folderTask?.cancel(); folderGeneration &+= 1; folderIDs = []; folderSizes = []; folderVersion = nil; folderLoad = .failed("The engine reported an internal error. Rescan to continue."); markOutOfDate("The engine reported an internal error, so the numbers may be wrong. Rescan to continue.") }
    func markOutOfDate(_ reason: String) { viewOutOfDate = true; outOfDateReason = reason; requiredVersion = nil }
    /// Called after each surface publishes. Clears the pending requirement only when ALL live surfaces are current.
    func surfaceCheck() {
        guard let r = requiredVersion else { return }
        let layoutOK = tab != .treemap || layoutVersion == r || layoutNotRenderableVersion == r
        if outlineVersion == r, derivedVersion == r, layoutOK { requiredVersion = nil; pendingTimeout?.cancel(); pendingTimeout = nil } else {
            // Deadline restarts only on the FIRST time a surface reaches r for this requirement; repeated publishes of an
            // already-current surface or tab changes do not reset it, so the bounded forced-refresh stage persists.
            var fresh = false
            if outlineVersion == r, progressedSurfaces.insert("outline").inserted { fresh = true }
            if derivedVersion == r, progressedSurfaces.insert("derived").inserted { fresh = true }
            if layoutVersion == r, progressedSurfaces.insert("layout").inserted { fresh = true }
            if fresh { startPendingTimeout() }
        }
    }
    /// The treemap reported (keyed by table version) that it cannot render (no tree, size <= 1, or view removed), so it
    /// does not hold the actions. Cleared when a layout publishes or a new tree arrives.
    var layoutNotRenderableVersion: UInt64?
    func layoutNotRenderable() { layoutNotRenderableVersion = tree?.version; surfaceCheck() }
    /// True when the treemap tab is showing but its layout is not at the current table version (needs an explicit relayout).
    var layoutNeedsRelayout: Bool { tab == .treemap && tree != nil && layoutVersion != tree?.version }
    private var pendingTimeout: Task<Void, Never>?
    private var progressedSurfaces: Set<String> = []
    /// Deadline step (nanoseconds); a var so a test can shorten it. The 10 s default is an unvalidated guess.
    var pendingStepNanos: UInt64 = 10_000_000_000
    /// Bounded wait: if a required surface never lands, surface an explicit error instead of blocking actions forever.
    func startPendingTimeout() {
        pendingTimeout?.cancel()
        pendingTimeout = Task { @MainActor [weak self] in
            // Deadline restarts on every surface publication (see surfaceCheck). On expiry: one forced refresh and one
            // extension, then an explicit error. The 10 s values are unvalidated guesses, not measured.
            for stage in 0..<2 {
                guard let step = self?.pendingStepNanos else { return }
                try? await Task.sleep(nanoseconds: step)
                guard !Task.isCancelled, let self, self.requiredVersion != nil else { return }
                if stage == 0 { self.refreshOutline(); if self.filterIsActive { self.scheduleFilter(immediate: true) }; self.layoutRetryToken &+= 1 }
            }
            guard let self, !Task.isCancelled, self.requiredVersion != nil else { return }
            self.markOutOfDate("The view did not finish updating after a change. Rescan to continue.")
        }
    }
    func layoutPublished(_ version: UInt64) { layoutVersion = version; layoutNotRenderableVersion = nil; surfaceCheck() }

    var filterInputKey: Int {
        var h = Hasher(); h.combine(filterText); h.combine(filterKind?.rawValue); h.combine(filterMinMB); h.combine(filterMaxMB)
        h.combine(filterModifiedDays); h.combine(filterExt); h.combine(tree.map(ObjectIdentifier.init)); h.combine(tree?.version); return h.finalize()
    }
    var derivedInputKey: Int { var h = Hasher(); h.combine(activeFilter.map(ObjectIdentifier.init)); h.combine(tree.map(ObjectIdentifier.init)); h.combine(tree?.version); return h.finalize() }
    var outlineInputKey: Int {
        var h = Hasher(); h.combine(displayedRoot); h.combine(expanded); h.combine(activeFilter.map(ObjectIdentifier.init))
        h.combine(outlineSort.rawValue); h.combine(tree.map(ObjectIdentifier.init)); h.combine(tree?.version); return h.finalize()
    }
    /// Key for the layout retry: the treemap inputs (root, size, filter, tree), supplied by the view.
    func layoutInputKey(root: UInt32, size: CGSize) -> Int {
        var h = Hasher(); h.combine(root); h.combine(size.width); h.combine(size.height); h.combine(activeFilter.map(ObjectIdentifier.init)); h.combine(tree.map(ObjectIdentifier.init)); h.combine(tree?.version); return h.finalize()
    }

    // MARK: bounded, keyed retry for BUSY (one slot per key; the action re-reads CURRENT inputs, never captured old ones)
    @ObservationIgnored private var retryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var retryAttempts: [String: Int] = [:]
    @ObservationIgnored private var retryGeneration: [String: Int] = [:]
    /// One slot per key. `inputs` identifies WHAT is being retried (a hash of the current inputs, not a request counter that
    /// every retry bumps): new inputs reset the attempt count, the same inputs keep counting toward the bound.
    func retryBusy(_ key: String, inputs generation: Int, _ action: @escaping @MainActor () -> Void) {
        let sameInputs = retryGeneration[key] == generation   // captured BEFORE the reset below
        if !sameInputs { retryAttempts[key] = nil; retryGeneration[key] = generation }
        // Same inputs and a retry already waiting: repeated calls (a view re-reading several times, several callers) must not
        // consume attempts or restart the timer; only a retry that actually FIRED counts toward the bound.
        if retryTasks[key] != nil, sameInputs { return }
        let n = (retryAttempts[key] ?? 0) + 1
        retryTasks[key]?.cancel()
        // Presentation-only reads (the selected node's details) must not escalate to a global out-of-date state: after the
        // bounded fast retries they keep a persistent "Updating" placeholder and retry slowly, forever cheap (one capture / 2 s).
        if key == "node" && n > 5 {
            retryAttempts[key] = 5
            retryTasks[key] = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                self?.retryTasks[key] = nil
                action()
            }
            return
        }
        guard n <= 5 else {
            retryAttempts[key] = nil; retryTasks[key] = nil
            markOutOfDate("The engine stayed busy and the list could not be refreshed. Rescan, or try again.")
            return
        }
        retryAttempts[key] = n
        retryTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(100_000_000 * n))
            if Task.isCancelled { return }
            self?.retryTasks[key] = nil
            action()
        }
    }
    func retryDone(_ key: String) { retryAttempts[key] = nil; retryTasks[key]?.cancel(); retryTasks[key] = nil }

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
        scanGeneration &+= 1
        let generation = scanGeneration, barrier = beforePublish, completed = afterPublish
        scanning = true
        error = nil
        rootPath = path
        // A scan that overlaps a filesystem change cannot prove it includes that change.
        let epochAtStart = fsEpoch, mutatingAtStart = mutationPending || commitsInFlight > 0
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
                let publication = UUID()
                Task { @MainActor in
                    await barrier?("scan-progress", generation, publication)
                    if let self, self.scanGeneration == generation, self.session === s {
                        self.progress = snap
                        self.elapsed = Date().timeIntervalSince(start)
                    }
                    await completed?("scan-progress", generation, publication)
                }
            }
            let publication = UUID()
            await barrier?("scan-completion", generation, publication)
            guard scanGeneration == generation, session === s else {
                await completed?("scan-completion", generation, publication)
                return
            }
            scanning = false
            lastScanSeconds = Date().timeIntervalSince(start)
            session = nil
            if let t {
                // Node ids are only valid for one tree: drop every id-keyed cache in the same main-actor turn
                // so no view can index the new tree with ids from the old one.
                filterTask?.cancel(); derivedTask?.cancel(); outlineTask?.cancel()
                outlineRows = []; outlineInfos = []; outlineShown = []; outlineIndex = [:]; outlineRevision += 1; expanded = []; largestIDs = []; largestSizes = []; kindRows = []; activeFilter = nil
                outlineRootSize = 0; publishedTotalBytes = nil; outlineVersion = nil; derivedVersion = nil; layoutVersion = nil; layoutNotRenderableVersion = nil; requiredVersion = nil
                pendingRemoval = nil
                invalidateFolders()
                exportTask?.cancel()   // an export prepared for the old tree must not write
                if fsEpoch != epochAtStart || mutatingAtStart || mutationPending || commitsInFlight > 0 {
                    markOutOfDate("Files were moved while this scan ran, so it may not match the disk. Rescan.")
                } else { viewOutOfDate = false; outOfDateReason = nil }
                tree = t
                panicBaseline = s.validatedPanicCount   // exactly the value ScanSession validated, not a fresh read
                poisoned = false
                startPoisonWatch()
                nodeCache = nil
                displayedRoot = 0
                selected = nil
                revision += 1
                scheduleFilter()
                refreshOutline()
            } else {
                error = "The scan failed. Check that the folder exists and you can read it."
            }
            await completed?("scan-completion", generation, publication)
        }
    }

    /// Drops every Folders row and any load in flight at once (tree changed, replaced, or a removal bumped `revision`).
    func invalidateFolders() {
        folderTask?.cancel(); folderTask = nil
        folderGeneration &+= 1
        folderIDs = []; folderSizes = []; folderVersion = nil
        folderLoad = .idle
    }

    /// What the Largest and Kinds lists show right now.
    /// `.ready`: current publication. `.retained(why)`: ONLY a pending filter edit on an otherwise current table: the last coherent
    /// publication stays visible, dimmed, selection disabled (no spinner flash per keystroke). `.updating(why)`: the table moved, a
    /// removal/commit is settling, the view is out of date, or nothing is published yet: rows, counts and bars are WITHHELD (a removed
    /// item is never shown as live). `.unavailable`: engine poisoned, nothing at all.
    enum DerivedPresentation: Equatable { case ready, retained(String), updating(String), unavailable(String) }
    var derivedPresentation: DerivedPresentation {
        if enginePoisoned { return .unavailable("The engine reported an internal error. Rescan to continue.") }
        guard let tree else { return .updating("Updating…") }
        if viewOutOfDate { return .updating(outOfDateReason ?? "The results may be out of date. Rescan to refresh.") }
        if rowsPending { return .updating("Updating after a change…") }
        guard let v = derivedVersion, v == tree.version else { return .updating("Updating…") }
        if filterPending { return .retained("Updating the filter…") }
        if let f = activeFilter, f.version != tree.version { return .retained("Updating the filter…") }
        return .ready
    }
    /// Explicit user retry for a derived list stuck in `.updating` (a publication that never arrived). Resets the bounded retry state.
    func retryDerived() { retryDone("derived"); refreshDerived() }

    func refreshFolders() { startFolderLoad(attempt: 0) }

    /// Reads the largest folders off the main actor and publishes only if the generation, the tree and the table version still match.
    /// A version mismatch retries at most `folderMaxAttempts` times with a short backoff, shown as loading, then ends as a failure.
    private func startFolderLoad(attempt: Int) {
        folderTask?.cancel()
        folderGeneration &+= 1
        let generation = folderGeneration
        folderIDs = []; folderSizes = []; folderVersion = nil
        guard let tree else { folderLoad = .idle; return }
        if enginePoisoned { folderLoad = .failed("The engine reported an internal error. Rescan to continue."); return }
        folderLoad = .loading
        let loader = folderLoader
        folderTask = Task.detached(priority: .userInitiated) { [weak self] in
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 50_000_000) }
            if Task.isCancelled { return }
            let result = await loader(tree, AppModel.folderCount)
            if Task.isCancelled { return }
            await MainActor.run { self?.applyFolderResult(result, tree: tree, generation: generation, attempt: attempt) }
        }
    }

    /// The only place rows are published. Ignores an answer for another generation or tree, and a version that is not the tree's now.
    func applyFolderResult(_ result: Result<FolderSnapshot, EngineStatus>, tree: Tree, generation: UInt64, attempt: Int) {
        guard folderGeneration == generation, self.tree === tree else { return }
        if enginePoisoned { folderIDs = []; folderSizes = []; folderVersion = nil; folderLoad = .failed("The engine reported an internal error. Rescan to continue."); return }
        switch result {
        case .success(let snap) where snap.version == tree.version:
            folderIDs = snap.ids; folderSizes = snap.sizes; folderVersion = snap.version; folderLoad = .ready
        case .success:
            if attempt + 1 < Self.folderMaxAttempts { startFolderLoad(attempt: attempt + 1) }
            else { folderIDs = []; folderSizes = []; folderVersion = nil; folderLoad = .failed("The results kept changing while loading. Try again.") }
        case .failure:
            folderIDs = []; folderSizes = []; folderVersion = nil; folderLoad = .failed("The folder list could not be read. Rescan to refresh.")
        }
    }

    func cancel() { session?.cancel() }

    func drill(into id: UInt32) {
        guard let tree, !navigationBlocked else { return }
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

    /// True ONLY when the published filter is current and the item is genuinely outside it (hidden from every view).
    func isOutsideFilter(_ id: UInt32) -> Bool {
        guard let f = activeFilter, filterUntrustedReason == nil else { return false }
        return f.count(id) == 0
    }
    /// Why the active filter cannot be used to judge an item right now (nil when it can, or when no filter is active).
    /// Not "outside the filter": a stale filter version or a caught engine panic is a different, accurate refusal.
    var filterUntrustedReason: String? {
        guard let f = activeFilter else { return nil }
        if enginePoisoned { return "The engine reported an internal error, so the filter result cannot be trusted. Rescan to continue." }
        if f.version != tree?.version { return "The filter result is out of date and is being recomputed. Nothing was moved; try again in a moment." }
        return nil
    }

    /// Why removal is unavailable right now, or nil when it is allowed.
    /// One node's details from ONE engine capture at the current table version, with its name and path. nil while rows are
    /// pending or the engine answers STALE/BUSY/INVALID: callers show a placeholder, never an old or zero size.
    struct NodeSnapshot { let id: UInt32; let version: UInt64; let info: NodeInfo; let name: String; let path: String }
    @ObservationIgnored private var nodeCache: NodeSnapshot?
    @ObservationIgnored private var nodeCacheTree: ObjectIdentifier?
    /// Test seam: replaces the engine read for the selected-node snapshot (nil in the app).
    @ObservationIgnored var nodeCheckedOverride: ((Tree, UInt32) -> Result<(info: NodeInfo, version: UInt64), EngineStatus>)?
    func retryPending(_ key: String) -> Bool { retryTasks[key] != nil }
    /// Views read this so a bounded retry re-renders them (a view body must not mutate state itself).
    var nodeRetryToken = 0
    func nodeSnapshot(_ id: UInt32) -> NodeSnapshot? {
        guard let tree, !rowsPending, !enginePoisoned, UInt64(id) < tree.nodeCount else { return nil }
        _ = nodeRetryToken
        switch nodeCheckedOverride?(tree, id) ?? tree.nodeChecked(id) {
        case .success(let r):
            let snap = NodeSnapshot(id: id, version: r.version, info: r.info, name: tree.name(id), path: tree.path(id))
            nodeCache = snap; nodeCacheTree = ObjectIdentifier(tree)
            retryDone("node")
            return snap
        case .failure(let st):
            // BUSY: reuse the last validated snapshot of THIS node only if it is still at the current table version, and
            // retry (bounded, keyed by node and version) so the view re-renders; STALE/INVALID: nothing is shown as a number.
            let cached = (nodeCacheTree == ObjectIdentifier(tree) && nodeCache?.id == id && nodeCache?.version == tree.version) ? nodeCache : nil
            if st == .busy || st == .stale {
                let key = nodeRetryKey(id, tree)
                Task { @MainActor [weak self] in self?.retryBusy("node", inputs: key) { [weak self] in self?.nodeRetryToken &+= 1 } }
            }
            return cached
        }
    }
    private func nodeRetryKey(_ id: UInt32, _ tree: Tree) -> Int { var h = Hasher(); h.combine(id); h.combine(ObjectIdentifier(tree)); h.combine(tree.version); return h.finalize() }

    func removalBlockedReason(_ id: UInt32) -> String? {
        if destructiveBlocked { return coherenceNotice ?? "Please wait for the previous change to finish." }
        if filterPending { return "The filter is still updating." }
        if let r = filterUntrustedReason { return r }
        if isOutsideFilter(id) { return "This item is outside the current filter. Clear the filter or select it again." }
        return nil
    }

    func proposeRemoval(of id: UInt32) {
        guard id != 0 else { return }
        if destructiveBlocked { removalMessage = coherenceNotice ?? "Please wait for the previous change to finish."; return }
        // A selection the filter has hidden must not be removable from here: clear the filter or reselect first.
        if removalInFlight { removalMessage = "Another removal is still in progress."; return }
        if filterPending { removalMessage = "The filter is still updating, so the list may be out of date. Try again in a moment."; return }
        if let r = filterUntrustedReason { removalMessage = r; return }
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

    /// Result of the filesystem half of a removal. Carries only Sendable values so it can cross from the background task.
    enum RemovalOutcome: Sendable {
        case moved(URL)
        case failed(String, originalStillExists: Bool)
    }
    enum UndoOutcome: Sendable {
        case restored
        case collision
        case failed(String)
    }
    /// `trashItem` is a plain closure so tests can mock it; it is only ever called from one background task at a time
    /// (removalInFlight serializes), which is the invariant this wrapper relies on.
    private struct SerialOperation: @unchecked Sendable { let run: (URL) throws -> URL }

    func confirmRemoval() {
        guard let tree, let id = pendingRemoval else { return }
        pendingRemoval = nil
        if removalInFlight { removalMessage = "Another removal is still in progress."; return }
        if filterPending { removalMessage = "The filter is still updating, so nothing was moved. Select the item again in a moment."; return }
        if let r = filterUntrustedReason { removalMessage = r; return }
        if isOutsideFilter(id) { removalMessage = "The filter changed and this item is no longer shown, so nothing was moved. Select it again to remove it."; return }
        let path = tree.path(id)
        if isProtected(path) {
            removalMessage = "\(path) is protected and cannot be removed from here."
            return
        }
        if destructiveBlocked { removalMessage = coherenceNotice ?? "Please wait for the previous change to finish."; return }
        let url = URL(fileURLWithPath: path)
        // The recorded size comes from one engine capture; if the engine cannot answer now, nothing is moved.
        guard let snap = nodeSnapshot(id) else { removalMessage = "Sizes are still updating, so nothing was moved. Try again in a moment."; return }
        let size = snap.info.size
        mutationPending = true      // reserved before the write, so no scan or undo can slip in between
        removalInFlight = true
        let op = SerialOperation(run: trashItem)
        // 1. The filesystem move runs OFF the main actor (it can take seconds on a slow volume). The tree is not touched
        // until the outcome is back on the main actor; mutationPending/removalInFlight stay set for the whole window.
        removalTask = Task { [weak self] in
            let outcome: RemovalOutcome = await Task.detached(priority: .userInitiated) {
                do { return .moved(try op.run(url)) }
                catch { return .failed(error.localizedDescription, originalStillExists: FileManager.default.fileExists(atPath: url.path)) }
            }.value
            self?.finishRemoval(outcome, id: id, url: url, size: size, tree: tree)
        }
    }

    private func finishRemoval(_ outcome: RemovalOutcome, id: UInt32, url: URL, size: UInt64, tree removedFrom: Tree) {
        removalInFlight = false
        switch outcome {
        case .failed(let reason, let stillExists):
            mutationPending = commitsInFlight > 0
            removalMessage = stillExists
                ? "Could not move it to the Trash: \(reason)"
                : "The Trash move reported an error (\(reason)) but \(url.lastPathComponent) is no longer at its original location. Rescan to refresh."
            if !stillExists { fsEpoch += 1; markOutOfDate("\(url.lastPathComponent) may have been moved even though the Trash reported an error. Rescan.") }
        case .moved(let trashed):
            // 2. Filesystem outcome journaled first (the real event), then the engine commit on the serial lane.
            fsEpoch += 1
            lastRemoved = [RemovedItem(original: url, trashed: trashed, size: size)]
            guard tree === removedFrom else {
                // A rescan replaced the tree while the move was running. Its node ids are gone; do not forget on the new one.
                mutationPending = commitsInFlight > 0
                markOutOfDate("\(url.lastPathComponent) was moved to the Trash while a scan was replacing the results, so they may still include it. Rescan.")
                removalMessage = "Moved \(url.lastPathComponent) to the Trash. The folder was rescanned meanwhile, so sizes may be out of date. Rescan to refresh."
                return
            }
            commitsInFlight += 1
            let name = url.lastPathComponent
            Task { [weak self] in
                if let hook = self?.beforeCommit { await hook() }     // test seam: park between the FS move and the commit
                let status: EngineStatus
                if let o = self?.commitOverride { status = await o(removedFrom, id) } else { status = await Self.commitLane.forget(removedFrom, id) }
                await MainActor.run { self?.finishCommit(tree: removedFrom, removed: id, status: status, name: name) }
            }
        }
    }

    /// Serial lane for engine mutations. Ordering does not rely on actor FIFO: confirmRemoval admits one removal at a
    /// time (commitsInFlight/mutationPending), and the engine's single writer mutex serializes the rest.
    static let commitLane = CommitLane()
    /// Test seams only (nil in the app).
    var beforeCommit: (() async -> Void)?
    var commitOverride: ((Tree, UInt32) async -> EngineStatus)?

    /// Publishes one removal on the main actor. Ordered after the filesystem outcome; every outcome is reported.
    /// One place for non-OK read statuses: BUSY is retried (bounded, keyed); STALE with a filter means the filter is old and
    /// is recomputed; anything else marks the view out of date. Nothing is shown as empty.
    private func handleReadFailure(_ status: EngineStatus?, key: String, inputs: Int, retry: @escaping @MainActor () -> Void) {
        switch status {
        case .busy: retryBusy(key, inputs: inputs, retry)
        case .stale:
            if !filterPending { if filterIsActive { scheduleFilter(immediate: true) } else { retryBusy(key, inputs: inputs, retry) } }
        default: markOutOfDate("The list could not be refreshed (\(status.map { "\($0)" } ?? "unknown")). Rescan.")
        }
    }

    private func finishCommit(tree: Tree, removed id: UInt32, status: EngineStatus, name: String) {
        commitsInFlight = max(0, commitsInFlight - 1)
        mutationPending = commitsInFlight > 0
        // The tree was replaced while the commit ran. The filesystem change is real and not necessarily in the new
        // tree (the scan may have read the folder before the move). Mark it explicitly instead of dropping the outcome.
        guard self.tree === tree else {
            markOutOfDate("\(name) was moved to the Trash while a scan was replacing the results, so they may still include it. Rescan.")
            removalMessage = "Moved \(name) to the Trash. The new results may not reflect it. Rescan to refresh."
            return
        }
        switch status {
        case .ok:
            // Clear every id-keyed piece of state inside the removed subtree in the same turn as the new numbers.
            if let s = selected, tree.isInside(s, subtreeOf: id) { selected = nil }
            expanded = expanded.filter { !tree.isInside($0, subtreeOf: id) }
            if tree.isInside(displayedRoot, subtreeOf: id) { displayedRoot = tree.info(id).parent ?? 0 }
            revision += 1
            // Rows and the layout on screen are the PREVIOUS publication until the recomputed ones land (no old row is
            // erased early), so actions that read them stay disabled until every surface reaches requiredVersion.
            requiredVersion = tree.version; layoutNotRenderableVersion = nil; progressedSurfaces = []; startPendingTimeout()   // comparison target only; surfaces carry the engine's own stamps
            if filterIsActive {
                // The active filter result belongs to the old table (STALE). Recompute without the typing debounce;
                // its landing refreshes outline, derived lists and layout.
                filterPending = true
                scheduleFilter(immediate: true)
            } else {
                refreshOutline()
                refreshDerived()
            }
            removalMessage = "Moved \(name) to the Trash."
        case .mutationFailed, .invalid, .internalError, .stale, .busy:
            // The file is in the Trash, but the numbers on screen could not be updated. Say so; never report success.
            markOutOfDate("\(name) is in the Trash but the numbers on screen could not be updated (\(status)). Rescan to refresh.")
            removalMessage = "Moved \(name) to the Trash, but the numbers on screen could not be updated (\(status)). Rescan to refresh. You can still put it back."
        }
    }

    /// Test/driver helper: waits for the removal task AND the engine commit it enqueues (bounded, 5 s). Returns false when
    /// a commit never settled; the caller must treat that as a failure, never as "settled".
    @discardableResult
    func settleRemoval() async -> Bool {
        await removalTask?.value
        for _ in 0..<500 where commitsInFlight > 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
        let ok = commitsInFlight == 0
        #if SPZ_CI_TESTS
        if !ok { Check.expect("removal-commit-never-settled", false, "commitsInFlight=\(commitsInFlight) mutationPending=\(mutationPending)") }
        #endif
        return ok
    }

    func undoRemoval() {
        // Undo is a filesystem change too. It is refused while a removal or commit is mid-flight, and afterwards the view is
        // persistently out of date: the engine cannot add a subtree back, only a rescan can.
        if removalInFlight || mutationPending || commitsInFlight > 0 || requiredVersion != nil { removalMessage = "The previous change is still being applied. Try again in a moment."; return }
        guard !lastRemoved.isEmpty else { return }
        let items = lastRemoved
        mutationPending = true
        removalInFlight = true
        removalTask = Task { [weak self] in
            let outcomes: [UndoOutcome] = await Task.detached(priority: .userInitiated) {
                items.map { item in
                    let fm = FileManager.default
                    if fm.fileExists(atPath: item.original.path) { return UndoOutcome.collision }
                    do { try fm.moveItem(at: item.trashed, to: item.original); return .restored }
                    catch { return .failed(error.localizedDescription) }
                }
            }.value
            self?.finishUndo(items, outcomes)
        }
    }

    private func finishUndo(_ items: [RemovedItem], _ outcomes: [UndoOutcome]) {
        removalInFlight = false
        mutationPending = commitsInFlight > 0
        var remaining: [RemovedItem] = []
        var message: String?
        for (item, outcome) in zip(items, outcomes) {
            switch outcome {
            case .restored:
                fsEpoch += 1
                markOutOfDate("Restored on disk. Rescan to bring it back.")
                message = message ?? "Put \(item.original.lastPathComponent) back. Restored on disk. Rescan to bring it back."
            case .collision: remaining.append(item); message = "Could not put it back: something already exists at \(item.original.path)."
            case .failed(let reason): remaining.append(item); message = "Could not put it back: \(reason)"
            }
        }
        lastRemoved = remaining   // only successful restores are forgotten
        removalMessage = message
    }

    func reveal(_ id: UInt32) {
        guard let tree, !navigationBlocked else { return }
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

/// Serializes engine mutations off the main actor. A removal's filesystem move happens before it is enqueued.
extension Result { var failureStatus: EngineStatus? { if case .failure(let e) = self { return e as? EngineStatus } else { return nil } } }

actor CommitLane {
    func forget(_ tree: Tree, _ id: UInt32) -> EngineStatus { tree.forget(id) }
}
