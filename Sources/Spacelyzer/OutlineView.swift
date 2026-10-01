import CSpacelyzer
import SwiftUI

struct OutlineView: View {
    @Environment(AppModel.self) private var model
    static let rowHeight: CGFloat = 28

    var body: some View {
        if let tree = model.tree {
            let total = max(1, model.activeFilter?.size(model.displayedRoot) ?? tree.info(model.displayedRoot).size)
            let rows = model.outlineRows
            // Windowed: LazyVStack creates only the rows on screen, so 150k rows cost the same as 50.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(0..<rows.count, id: \.self) { i in
                            let row = rows[i]
                            OutlineLine(tree: tree, node: row.node, depth: Int(row.depth), parentTotal: total)
                                .frame(height: Self.rowHeight)
                                .padding(.horizontal, 8)
                                .background(model.selected == row.node ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .onTapGesture { model.selected = row.node }
                                .id(row.node)
                                .contextMenu {
                                    Button("Show in Finder") { model.reveal(row.node) }
                                    Button("Move to Trash…", role: .destructive) { model.proposeRemoval(of: row.node) }
                                }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { move(+1, rows, proxy) }
                .onKeyPress(.upArrow) { move(-1, rows, proxy) }
                .onKeyPress(.rightArrow) { expand(true, tree) }
                .onKeyPress(.leftArrow) { expand(false, tree) }
                .onKeyPress(.return) { if let s = model.selected { model.drill(into: s) }; return .handled }
            }
            .overlay {
                if model.activeFilter != nil && rows.isEmpty {
                    ContentUnavailableView("No matches", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Nothing in this folder matches the current filter."))
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .onAppear { model.refreshOutline() }
        } else {
            ProgressView("Scanning…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func move(_ d: Int, _ rows: [SpzRow], _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let cur = model.selected.flatMap { s in rows.firstIndex(where: { $0.node == s }) }
        let next = max(0, min(rows.count - 1, (cur ?? (d > 0 ? -1 : rows.count)) + d))
        model.selected = rows[next].node
        proxy.scrollTo(rows[next].node)
        return .handled
    }

    private func expand(_ open: Bool, _ tree: Tree) -> KeyPress.Result {
        guard let s = model.selected else { return .ignored }
        let info = tree.info(s)
        if info.kind == .directory && info.childCount > 0 && model.expanded.contains(s) != open { model.toggle(s); return .handled }
        return .ignored
    }
}

struct OutlineLine: View {
    @Environment(AppModel.self) private var model
    let tree: Tree
    let node: UInt32
    let depth: Int
    let parentTotal: UInt64

    var body: some View {
        let info = tree.info(node)
        let shown = model.activeFilter?.size(node) ?? info.size
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * 10, height: 1)
            if info.kind == .directory && info.childCount > 0 {
                Button { model.toggle(node) } label: {
                    Image(systemName: model.expanded.contains(node) ? "chevron.down" : "chevron.right").font(.caption2)
                }.buttonStyle(.plain).frame(width: 12)
            } else { Color.clear.frame(width: 12, height: 1) }
            Image(systemName: icon(info))
                .foregroundStyle(info.kind == .directory ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(tree.name(node)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(formatBytes(shown)).monospacedDigit().foregroundStyle(.secondary)
            ShareBar(fraction: Double(shown) / Double(parentTotal))
                .frame(width: 44, height: 6)
        }
    }

    private func icon(_ i: NodeInfo) -> String {
        switch i.kind {
        case .directory: "folder"
        case .package: "app.gift"
        case .symlink: "link"
        case .file: "doc"
        }
    }
}

struct ShareBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.accentColor.opacity(0.7)).frame(width: max(2, g.size.width * min(1, fraction)))
            }
        }
    }
}
