import SwiftUI

/// One row of the hierarchy. Children are produced only when a row is expanded.
struct OutlineRow: Identifiable, Hashable {
    let id: UInt32
    let tree: Tree

    static func == (a: OutlineRow, b: OutlineRow) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// Largest 2,000 children; the long tail of tiny items is summarised by the parent's size.
    var children: [OutlineRow]? {
        let info = tree.info(id)
        guard info.kind == .directory, info.childCount > 0 else { return nil }
        let r = tree.children(id)
        let capped = r.lowerBound..<min(r.upperBound, r.lowerBound + 2000)
        return capped.filter { tree.info($0).size > 0 }.map { OutlineRow(id: $0, tree: tree) }
    }
}

struct OutlineView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let tree = model.tree {
            let root = OutlineRow(id: model.displayedRoot, tree: tree)
            let total = max(1, tree.info(model.displayedRoot).size)
            List(selection: $model.selected) {
                OutlineGroup(root.children ?? [], children: \.children) { row in
                    OutlineLine(row: row, parentTotal: total)
                        .tag(row.id)
                        .contextMenu {
                            Button("Show in Finder") { model.reveal(row.id) }
                            Button("Move to Trash…", role: .destructive) { model.proposeRemoval(of: row.id) }
                        }
                }
            }
            .id(model.revision * 1_000_003 + Int(model.displayedRoot))
            .listStyle(.sidebar)
        } else {
            ProgressView("Scanning…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct OutlineLine: View {
    let row: OutlineRow
    let parentTotal: UInt64

    var body: some View {
        let info = row.tree.info(row.id)
        HStack(spacing: 6) {
            Image(systemName: icon(info))
                .foregroundStyle(info.kind == .directory ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(row.tree.name(row.id)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(formatBytes(info.size)).monospacedDigit().foregroundStyle(.secondary)
            ShareBar(fraction: Double(info.size) / Double(parentTotal))
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
