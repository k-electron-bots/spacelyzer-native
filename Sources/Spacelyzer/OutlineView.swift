import CSpacelyzer
import SwiftUI

struct OutlineView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let tree = model.tree {
            let total = max(1, model.activeFilter?.size(model.displayedRoot) ?? tree.info(model.displayedRoot).size)
            // Rows come from Rust already flattened; List only builds the rows on screen.
            List(selection: $model.selected) {
                ForEach(model.outlineRows, id: \SpzRow.node) { row in
                    OutlineLine(tree: tree, node: row.node, depth: Int(row.depth), parentTotal: total)
                        .tag(row.node)
                        .contextMenu {
                            Button("Show in Finder") { model.reveal(row.node) }
                            Button("Move to Trash…", role: .destructive) { model.proposeRemoval(of: row.node) }
                        }
                }
            }
            .listStyle(.sidebar)
            .onAppear { model.refreshOutline() }
        } else {
            ProgressView("Scanning…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
            Color.clear.frame(width: CGFloat(depth) * 14, height: 1)
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
