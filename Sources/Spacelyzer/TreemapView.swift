import AppKit
import SwiftUI

/// Hues spaced by the golden angle keep neighbouring branches far apart in colour.
func branchColor(_ branch: Int) -> Color {
    let hue = (Double(branch) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
    return Color(hue: hue, saturation: 0.55, brightness: 0.85)
}

func categoryColor(_ c: FileCategory) -> Color {
    switch c {
    case .folder: .gray
    case .image: .teal
    case .video: .purple
    case .audio: .pink
    case .document: .blue
    case .archive: .brown
    case .code: .green
    case .application: .orange
    case .data: .indigo
    case .font: .mint
    case .other: .secondary
    }
}


private struct TreemapBase: View, Equatable {
    let layout: TreemapLayout
    let tree: Tree
    let coloring: TreemapColoring
    static func == (a: Self, b: Self) -> Bool { a.layout === b.layout && a.tree === b.tree && a.coloring == b.coloring }
    var body: some View {
        Canvas { ctx, _ in
            for r in layout.rects where !r.isDirectoryFrame || r.depth <= 1 {
                let color = fill(r, tree: tree, coloring: coloring)
                let path = Path(roundedRect: r.rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 1.5)
                ctx.fill(path, with: .color(r.isDirectoryFrame ? color.opacity(0.18) : color))
            }
            // Labels only where they fit.
            for r in layout.rects where !r.isDirectoryFrame && !r.isRemainder && r.rect.width > 70 && r.rect.height > 22 {
                let box = r.rect.insetBy(dx: 4, dy: 3)
                let label = fitLabel(tree.name(r.node), width: box.width, ctx: ctx)
                ctx.drawLayer { l in
                    l.clip(to: Path(box))
                    l.draw(label, at: CGPoint(x: box.minX, y: box.minY), anchor: .topLeading)
                }
            }
        }
        .drawingGroup()
    }
}

/// One line, middle-truncated with an ellipsis to fit `width`. Never wraps or splits a name.
func fitLabel(_ name: String, width: CGFloat, ctx: GraphicsContext) -> GraphicsContext.ResolvedText {
    func resolved(_ t: String) -> GraphicsContext.ResolvedText {
        ctx.resolve(Text(t).font(.system(size: 11, weight: .medium)).foregroundColor(.white))
    }
    var r = resolved(name)
    if r.measure(in: CGSize(width: 10_000, height: 20)).width <= width { return r }
    var chars = Array(name)
    while chars.count > 3 {
        chars.removeSubrange((chars.count / 2)..<(chars.count / 2 + 1))
        let keep = chars.count / 2
        let candidate = String(chars[..<keep]) + "…" + String(chars[keep...])
        r = resolved(candidate)
        if r.measure(in: CGSize(width: 10_000, height: 20)).width <= width { return r }
        chars = Array(candidate.replacingOccurrences(of: "…", with: ""))
    }
    return resolved("…")
}

func fill(_ r: TreemapRect, tree: Tree, coloring: TreemapColoring) -> Color {
    if r.isRemainder { return Color(nsColor: .quaternaryLabelColor) }
    let depth = Double(min(6, max(0, r.depth)))
    switch coloring {
    case .folder: return branchColor(r.branch).opacity(0.55 + depth * 0.07)
    case .kind: return categoryColor(tree.info(r.node).category).opacity(0.55 + depth * 0.07)
    case .depth: return Color(hue: 0.58, saturation: 0.55, brightness: 0.28 + depth * 0.11)
    }
}


/// Optional CI hook. With nil (normal app), no waits or evidence callbacks occur.
@MainActor final class TreemapPublicationProbe {
    var before: (@Sendable (UUID, UInt64, CGSize, ObjectIdentifier, ObjectIdentifier?) async -> Void)?
    var after: ((UUID, UInt64, CGSize, ObjectIdentifier, ObjectIdentifier?, Bool, TreemapPublicationEvidence) -> Void)?
    var readEvidence: (() -> TreemapPublicationEvidence)?
    var disappeared: ((UInt64, TreemapPublicationEvidence) -> Void)?
}
struct TreemapPublicationEvidence {
    let layoutID: ObjectIdentifier?
    let treeID: ObjectIdentifier?
    let filterID: ObjectIdentifier?
    let size: CGSize
    let hitValid: Bool
}

struct TreemapView: View {
    var publicationProbe: TreemapPublicationProbe? = nil
    @Environment(AppModel.self) private var model
    @State private var size: CGSize = .zero
    @State private var layout: TreemapLayout?
    @State private var hovered: TreemapRect?
    @State private var task: Task<Void, Never>?
    @State private var generation: UInt64 = 0
    @State private var layoutRevision: Int = -1
    @State private var layoutRoot: UInt32?
    @State private var layoutFilter: FilterResult?
    @State private var layoutSize: CGSize = .zero
    private var currentLayout: TreemapLayout? {
        guard let tree = model.tree, let layout, layout.treeID == ObjectIdentifier(tree),
              layoutRevision == model.revision, layoutRoot == model.displayedRoot, layoutFilter === model.activeFilter, layoutSize == size else { return nil }
        return layout
    }

    var body: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                if let layout, let tree = model.tree, layout.treeID == ObjectIdentifier(tree) {
                    ZStack(alignment: .topLeading) {
                        // Base layer: its own Equatable view, so hover and selection never redraw it.
                        TreemapBase(layout: layout, tree: tree, coloring: model.coloring).equatable()
                        // Thin overlay for hover and selection, so pointer moves are cheap.
                        Canvas { ctx, _ in
                            if let h = hovered {
                                ctx.stroke(Path(h.rect), with: .color(.white.opacity(0.9)), lineWidth: 2)
                            }
                            if let s = model.selected, let r = layout.rects.last(where: { $0.node == s }) {
                                ctx.stroke(Path(r.rect), with: .color(.accentColor), lineWidth: 3)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    .frame(width: layout.size.width, height: layout.size.height)
                }
            }
            .clipped()
            .overlay {
                if !model.filterPending, !model.enginePoisoned, model.activeFilter != nil, let currentLayout, currentLayout.rects.isEmpty {
                    if model.activeFilter?.count(model.displayedRoot) == 0 {
                        ContentUnavailableView("No matches", systemImage: "line.3.horizontal.decrease.circle")
                    } else {
                        ContentUnavailableView("Matching items use no drawable space", systemImage: "square.dashed",
                                               description: Text("Zero allocated bytes cannot make a treemap region. See these items in the outline or Largest list."))
                    }
                }
            }
            .contentShape(Rectangle())
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0; relayout() }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hovered = currentLayout?.hit(p)
                case .ended: hovered = nil
                }
            }
            .gesture(
                SpatialTapGesture(count: 2).onEnded { v in
                    if let r = currentLayout?.hit(v.location) { model.drill(into: r.isRemainder ? r.node : r.node) }
                }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 1).onEnded { v in
                    if let r = currentLayout?.hit(v.location) { model.selected = r.node }
                }
            )
            .overlay(alignment: .bottom) { readout }
            .onChange(of: model.displayedRoot) { relayout() }
            .onChange(of: model.revision) { hovered = nil; relayout() }
            .onChange(of: model.filterRevision) { relayout() }
            .onChange(of: model.layoutRetryToken) { relayout() }
            .onAppear { relayout() }
            .onChange(of: model.tab) { if model.layoutNeedsRelayout { relayout() } }
            .onDisappear { task?.cancel(); generation &+= 1; hovered = nil; model.layoutNotRenderable(); publicationProbe?.disappeared?(generation, publicationEvidence()) }
    }

    @ViewBuilder private var readout: some View {
        // Hover shows the published layout's own size (same snapshot as the picture); hidden while that layout is not the current table version.
        if let h = hovered, let cl = currentLayout, cl.version == model.tree?.version, !model.rowsPending, !model.enginePoisoned, let tree = model.tree {
            let name = h.isRemainder ? "Smaller items in \(tree.name(h.node))" : tree.name(h.node)
            Text("\(name)  ·  \(formatBytes(h.size))")
                .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule()).padding(8)
        }
    }

    /// Reads private published state and the production currentLayout/hit path, not a copied gate.
    private func publicationEvidence() -> TreemapPublicationEvidence {
        let current = currentLayout
        let rect = current?.rects.first { !$0.isDirectoryFrame && $0.rect.width > 1 && $0.rect.height > 1 }
        let hit = rect.flatMap { current?.hit(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
        let valid = hit.map { h in model.tree.map { UInt64(h.node) < $0.nodeCount && h.node == rect?.node } ?? false } ?? false
        return TreemapPublicationEvidence(layoutID: current.map(ObjectIdentifier.init), treeID: current?.treeID, filterID: current != nil ? layoutFilter.map(ObjectIdentifier.init) : nil, size: current?.size ?? .zero, hitValid: valid)
    }

    /// Layout runs in Rust off the main thread; the previous picture stays up until the new one lands.
    private func relayout() {
        if let publicationProbe { publicationProbe.readEvidence = { publicationEvidence() } }
        task?.cancel()
        generation &+= 1
        let request = generation
        hovered = nil
        guard let tree = model.tree, size.width > 1, size.height > 1 else { layout = nil; model.layoutNotRenderable(); return }
        let root = model.displayedRoot, revision = model.revision
        let s = size, flt = model.activeFilter
        let barrier = publicationProbe?.before, completed = publicationProbe?.after
        task = Task.detached(priority: .userInitiated) {
            // Status API: a stale filter or BUSY is never drawn as an empty picture. The previous layout stays up.
            let result = tree.layoutChecked(root: root, size: s, filter: flt)
            guard case .success(let l) = result else {
                await MainActor.run {
                    guard !Task.isCancelled, generation == request, model.tree === tree else { return }
                    switch result.failureStatus {
                    case .busy:
                        // bounded and keyed by the model; the retry runs relayout(), which re-reads the CURRENT inputs
                        model.retryBusy("layout", inputs: model.layoutInputKey(root: root, size: s)) { model.layoutRetryToken &+= 1 }
                    case .stale:
                        // STALE: the filter handle is from an older table. If no recompute is pending, start one (bounded).
                        if !model.filterPending { model.retryBusy("layout-stale", inputs: model.layoutInputKey(root: root, size: s)) { model.scheduleFilter(immediate: true) } }
                    default:
                        model.markOutOfDate("The treemap could not be updated. Rescan.")
                    }
                }
                return
            }
            if Task.isCancelled { return }
            let token = (barrier != nil || completed != nil) ? UUID() : nil
            if let token { await barrier?(token, request, s, ObjectIdentifier(tree), flt.map(ObjectIdentifier.init)) }
            await MainActor.run {
                let accepted: Bool
                if model.enginePoisoned { model.markPoisoned(); accepted = false } else
                if !Task.isCancelled, generation == request, model.tree === tree, l.version == tree.version,
                   flt == nil || flt!.version == l.version,
                   model.revision == revision, model.displayedRoot == root, model.activeFilter === flt, size == s {
                    model.retryDone("layout"); model.retryDone("layout-stale"); model.layoutPublished(l.version)
                    layout = l
                    layoutRevision = revision; layoutRoot = root; layoutFilter = flt; layoutSize = s
                    hovered = nil
                    accepted = true
                } else { accepted = false }
                if let token { completed?(token, request, s, ObjectIdentifier(tree), flt.map(ObjectIdentifier.init), accepted, publicationEvidence()) }
            }
        }
    }
}

struct TrailingPane: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let notice = model.coherenceNotice {
                Text(notice).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 4)
            }
            switch model.tab {
            case .treemap:
                HStack {
                    Picker("Colour", selection: $model.coloring) {
                        ForEach(TreemapColoring.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 220)
                    Spacer()
                    if let t = model.tree { Text(t.name(model.displayedRoot).isEmpty ? model.rootPath : t.path(model.displayedRoot)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                }.padding(8)
                TreemapView().padding([.horizontal, .bottom], 8)
            case .kinds: KindsView().frame(maxHeight: .infinity)
            case .largest: LargestView().frame(maxHeight: .infinity)
            case .folders: FoldersView().frame(maxHeight: .infinity)
            }
            if let id = model.selected, let t = model.tree { SelectionBar(tree: t, id: id).fixedSize(horizontal: false, vertical: true).layoutPriority(1) }
        }
    }
}

struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    let tree: Tree
    let id: UInt32
    @State private var showReview = false
    var body: some View {
        // One engine capture for the numbers; a placeholder (never an old or zero size) while rows are pending or the engine is busy.
        let snap = model.nodeSnapshot(id)
        let title = snap.map { $0.name.isEmpty ? $0.path : $0.name } ?? (tree.name(id).isEmpty ? tree.path(id) : tree.name(id))
        let detail = snap.map { "\(formatBytes($0.info.size))  ·  \($0.info.category.label)" } ?? "Updating…"
        // Computed once per render for the menu state; the click decides AGAIN from the current state (copyScannedPath).
        let copyDecision = currentCopyDecision()
        let copyHelp: String = { if case .refuse(let r) = copyDecision { return r.help }; return "Copy the path the scan recorded for this item (not a check of the disk now)" }()
        HStack {
            VStack(alignment: .leading) {
                Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if model.isOutsideFilter(id) {
                    Text("Not in the current filter (still selected). Move to Trash is off until you clear the filter or reselect.").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                } else if let untrusted = model.filterUntrustedReason {
                    // Pending or error is shown as such, never as "not in the filter".
                    Text(untrusted).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu("More") {
                Button("Show in Finder") { model.reveal(id) }
                    .accessibilityLabel("Show selected item in Finder")
                Button("Copy Scanned Path") { copyScannedPath() }
                    .disabled(copyDecision.isRefused)
                    .accessibilityLabel("Copy the scanned path of the selected item")
            }
            .help(copyHelp)
            .accessibilityLabel("More actions for the selected item")
            Button("Check on disk…") { showReview = true }
                .disabled(model.enginePoisoned || model.mutationPending)
                .help("Read only: compare this item on disk with the scan")
                .accessibilityLabel("Check selected item on disk, read only")
                .popover(isPresented: $showReview, arrowEdge: .top) { ItemReviewPopover(model: model, tree: tree, id: id, dismiss: { showReview = false }) }
            Button("Move to Trash…", role: .destructive) { model.proposeRemoval(of: id) }
                .disabled(model.removalBlockedReason(id) != nil)
                .help(model.removalBlockedReason(id) ?? "")
                .accessibilityLabel("Move selected item to Trash")
        }.padding(10).background(.bar)
            .onChange(of: id) { _, _ in showReview = false }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Selected item: \(title), \(detail)")
    }
}

extension SelectionBar {
    /// Current decision from live state. The item must still be the selected node of the model's current tree.
    fileprivate func currentCopyDecision() -> CopyPathPolicy.Decision {
        let live = model.tree === tree && model.selected == id && UInt64(id) < tree.nodeCount
        return CopyPathPolicy.decide(path: live ? tree.path(id) : nil, enginePoisoned: model.enginePoisoned)
    }
    /// Read only. Decides again at click time and clears the clipboard only when it is about to write a valid path. Does not touch the
    /// disk, the tree or the selection. A refusal leaves the clipboard exactly as it was.
    fileprivate func copyScannedPath() {
        let live = model.tree === tree && model.selected == id && UInt64(id) < tree.nodeCount
        CopyPathPolicy.perform(path: live ? tree.path(id) : nil, enginePoisoned: model.enginePoisoned) { p in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(p, forType: .string)
        }
    }
}

extension CopyPathPolicy.Decision {
    var isRefused: Bool { if case .refuse = self { return true }; return false }
}

struct KindsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let t = model.tree {
            let presentation = model.derivedPresentation
            let rows: [KindRow] = { switch presentation { case .ready, .retained: return model.kindRows; default: return [] } }()      // only current or filter-pending rows; withheld when updating/poisoned
            let total = max(1, rows.reduce(0) { $0 + $1.bytes })
            List(rows) { r in
                HStack {
                    Circle().fill(categoryColor(r.category)).frame(width: 10, height: 10)
                    Text(r.category.label)
                    Spacer()
                    Text("\(r.items.formatted()) items").foregroundStyle(.secondary)
                    Text(formatBytes(r.bytes)).monospacedDigit().frame(width: 90, alignment: .trailing)
                    ShareBar(fraction: Double(r.bytes) / Double(total)).frame(width: 60, height: 6)
                }
            }
            .opacity(presentation == .ready ? 1 : 0.5)
            .disabled(presentation != .ready)
            .overlay { DerivedOverlay(presentation: presentation, retry: { model.retryDerived() }) }
        }
    }
}

/// Shown over a derived list (Kinds, Largest). Retained rows stay visible dimmed (caller); `.updating` withholds rows and shows a spinner with an explicit Retry.
struct DerivedOverlay: View {
    let presentation: AppModel.DerivedPresentation
    var retry: () -> Void = {}
    var body: some View {
        switch presentation {
        case .ready, .retained: EmptyView()
        case .updating(let why): VStack(spacing: 8) { ProgressView(why); Button("Try Again", action: retry) }
        case .unavailable(let why): ContentUnavailableView("Unavailable", systemImage: "exclamationmark.triangle", description: Text(why))
        }
    }
}

/// Largest folders by cumulative size, as the scan recorded them (not a check of the disk now). A folder and its parent can both appear.
/// Read only. Not filtered: the engine ranks all folders, and the note says so when a filter is active.
struct FoldersView: View {
    @Environment(AppModel.self) private var model
    private struct LoadKey: Hashable { var tree: ObjectIdentifier?; var revision: Int }
    var body: some View {
        if let t = model.tree {
            let ready = model.folderLoad == .ready && !model.enginePoisoned      // computed counter too, not only the stored flag
            let ids = ready ? model.folderIDs : []        // rows exist only when ready
            let sizes = ready ? model.folderSizes : []
            let sizeOf = Dictionary(zip(ids, sizes), uniquingKeysWith: { a, _ in a })
            List(ids, id: \.self, selection: Bindable(model).selected) { id in
                HStack {
                    VStack(alignment: .leading) {
                        Text(model.enginePoisoned ? "Unavailable" : t.name(id)).lineLimit(1)
                        Text(model.enginePoisoned ? "" : t.path(id)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    Text(sizeOf[id].map(formatBytes) ?? "\u{2014}").monospacedDigit()
                }.tag(id)
            }
            .disabled(!ready)
            .overlay {
                switch (model.enginePoisoned ? AppModel.FolderLoad.failed("The engine reported an internal error. Rescan to continue.") : model.folderLoad) {
                case .idle, .loading: ProgressView("Loading folders…")
                case .failed(let problem):
                    ContentUnavailableView {
                        Label("Folders unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(problem)
                    } actions: {
                        // Explicit retry that needs no tree change. Starts a fresh bounded load and shows "Loading folders…" meanwhile.
                        Button("Try Again") { model.refreshFolders() }
                            .disabled(model.enginePoisoned)
                            .accessibilityLabel("Try loading the folder list again")
                    }
                case .ready: if ids.isEmpty { ContentUnavailableView("No folders", systemImage: "folder", description: Text("The scan found no folder with any size.")) }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                // The count is shown only for a valid, loaded list. Never "0 folders" while loading or after an error.
                if ready {
                    Text((ids.count >= AppModel.folderCount ? "Showing the \(AppModel.folderCount) largest folders, by total size inside" : "\(ids.count.formatted()) folders, by total size inside") + (model.filterIsActive ? ". Not filtered." : ""))
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 4)
                }
            }
            .task(id: LoadKey(tree: model.tree.map(ObjectIdentifier.init), revision: model.revision)) { model.refreshFolders() }
        }
    }
}

struct LargestView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let t = model.tree {
            let presentation = model.derivedPresentation
            let blank: Bool = { switch presentation { case .ready, .retained: return false; default: return true } }()
            let ids = blank ? [] : model.largestIDs           // poisoned: nothing. stale: the previous publication, dimmed, not selectable
            let sizes = blank ? [] : model.largestSizes
            let sizeOf = Dictionary(zip(ids, sizes), uniquingKeysWith: { a, _ in a })   // sizes come from the same capture as the ids
            List(ids, id: \.self, selection: Bindable(model).selected) { id in
                HStack {
                    VStack(alignment: .leading) {
                        // A caught engine panic makes the legacy name/path reads untrustworthy (they fall back to blank).
                        Text(model.enginePoisoned ? "Unavailable" : t.name(id)).lineLimit(1)
                        Text(model.enginePoisoned ? "" : t.path(id)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    Text(sizeOf[id].map(formatBytes) ?? "\u{2014}").monospacedDigit()   // a missing size, or a poisoned engine, is a visible placeholder, never 0 B or an old number
                }.tag(id)
            }
            .opacity(presentation == .ready ? 1 : 0.5)
            .disabled(presentation != .ready)
            .overlay {
                if presentation != .ready { DerivedOverlay(presentation: presentation, retry: { model.retryDerived() }) }
                else if model.activeFilter != nil && ids.isEmpty {
                    ContentUnavailableView("No matches", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("No file matches the current filter."))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if presentation == .ready {   // count only for a current publication
                Text(ids.count >= 200 ? "Showing the 200 largest\(model.activeFilter != nil ? " matching" : "") files" : "\(ids.count.formatted()) \(model.activeFilter != nil ? "matching " : "")files")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 4)
                } else if case .retained(let why) = presentation {
                    Text(why).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 4)
                }
            }
        }
    }
}
