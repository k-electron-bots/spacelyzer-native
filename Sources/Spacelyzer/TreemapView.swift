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


struct TreemapView: View {
    @Environment(AppModel.self) private var model
    @State private var size: CGSize = .zero
    @State private var layout: TreemapLayout?
    @State private var hovered: TreemapRect?
    @State private var task: Task<Void, Never>?

    var body: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                if let layout, let tree = model.tree {
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
                if model.activeFilter != nil && (layout?.rects.isEmpty ?? false) {
                    ContentUnavailableView("No matches", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            .contentShape(Rectangle())
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0; relayout() }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hovered = layout?.hit(p)
                case .ended: hovered = nil
                }
            }
            .gesture(
                SpatialTapGesture(count: 2).onEnded { v in
                    if let r = layout?.hit(v.location) { model.drill(into: r.isRemainder ? r.node : r.node) }
                }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 1).onEnded { v in
                    if let r = layout?.hit(v.location) { model.selected = r.node }
                }
            )
            .overlay(alignment: .bottom) { readout }
            .onChange(of: model.displayedRoot) { relayout() }
            .onChange(of: model.revision) { relayout() }
            .onChange(of: model.filterRevision) { relayout() }
            .onAppear { relayout() }
    }

    @ViewBuilder private var readout: some View {
        if let h = hovered, let tree = model.tree {
            let name = h.isRemainder ? "Smaller items in \(tree.name(h.node))" : tree.name(h.node)
            Text("\(name)  ·  \(formatBytes(h.size))")
                .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule()).padding(8)
        }
    }

    /// Layout runs in Rust off the main thread; the previous picture stays up until the new one lands.
    private func relayout() {
        guard let tree = model.tree, size.width > 1, size.height > 1 else { return }
        let root = model.displayedRoot
        let s = size, flt = model.activeFilter
        task?.cancel()
        task = Task.detached(priority: .userInitiated) {
            let l = tree.layout(root: root, size: s, filter: flt)
            if Task.isCancelled { return }
            await MainActor.run { layout = l }
        }
    }
}

struct TrailingPane: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
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
            }
            if let id = model.selected, let t = model.tree { SelectionBar(tree: t, id: id).fixedSize(horizontal: false, vertical: true).layoutPriority(1) }
        }
    }
}

struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    let tree: Tree
    let id: UInt32
    var body: some View {
        let info = tree.info(id)
        HStack {
            VStack(alignment: .leading) {
                Text(tree.name(id).isEmpty ? tree.path(id) : tree.name(id)).font(.headline).lineLimit(1)
                Text("\(formatBytes(info.size))  ·  \(info.category.label)").font(.caption).foregroundStyle(.secondary)
                if let f = model.activeFilter, f.size(id) == 0 {
                    Text("Not in the current filter (still selected). Move to Trash is off until you clear the filter or reselect.").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Show in Finder") { model.reveal(id) }
            Button("Move to Trash…", role: .destructive) { model.proposeRemoval(of: id) }
                .disabled(model.removalBlockedReason(id) != nil)
                .help(model.removalBlockedReason(id) ?? "")
        }.padding(10).background(.bar)
    }
}

struct KindsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let t = model.tree {
            let rows = model.kindRows
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
        }
    }
}

struct LargestView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let t = model.tree {
            let ids = model.largestIDs
            List(ids, id: \.self, selection: Bindable(model).selected) { id in
                HStack {
                    VStack(alignment: .leading) {
                        Text(t.name(id)).lineLimit(1)
                        Text(t.path(id)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    Text(formatBytes(t.info(id).size)).monospacedDigit()
                }.tag(id)
            }
            .overlay {
                if model.activeFilter != nil && ids.isEmpty {
                    ContentUnavailableView("No matches", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("No file matches the current filter."))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Text(ids.count >= 200 ? "Showing the 200 largest\(model.activeFilter != nil ? " matching" : "") files" : "\(ids.count.formatted()) \(model.activeFilter != nil ? "matching " : "")files")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 4)
            }
        }
    }
}
