import AppKit
import CSpacelyzer
import SwiftUI

/// The outline is an NSTableView: AppKit virtualizes rows and scrolls to a row in O(1), which a LazyVStack could not do
/// for 150k rows (profiled: scrollTo and row re-evaluation dominated every arrow press).
struct OutlineView: View {
    @Environment(AppModel.self) private var model
    static let rowHeight: CGFloat = 28

    var body: some View {
        if let tree = model.tree {
            let total = max(1, model.activeFilter?.size(model.displayedRoot) ?? tree.info(model.displayedRoot).size)
            OutlineTable(model: model, tree: tree, total: total, revision: model.outlineRevision, selected: model.selected)
                .overlay {
                    if model.activeFilter != nil && model.outlineRows.isEmpty {
                        ContentUnavailableView("No matches", systemImage: "line.3.horizontal.decrease.circle",
                                               description: Text("Nothing in this folder matches the current filter."))
                    }
                }
                .onAppear { model.refreshOutline() }
                .onChange(of: model.selected) { _, n in
                    if let n { model.revealInOutline(n) }
                    guard Perf.on else { return }
                    let idx = n.flatMap { model.outlineIndex[$0] }
                    Perf.log("selection changed: node=\(n.map(String.init) ?? "nil") rowIndex=\(idx.map(String.init) ?? "none") of \(model.outlineRows.count)")
                }
        } else {
            ProgressView("Scanning…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private final class KeyTable: NSTableView {
    var onKey: ((UInt16) -> Bool)?
    var contextRow: ((Int) -> NSMenu?)?
    override func keyDown(with event: NSEvent) {
        if let h = onKey, h(event.keyCode) { return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let r = row(at: convert(event.locationInWindow, from: nil))
        return r >= 0 ? contextRow?(r) : nil
    }
}

private final class ShareBarView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        let w = max(2, r.width * min(1, max(0, fraction)))
        NSColor.controlAccentColor.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: r.height), xRadius: r.height / 2, yRadius: r.height / 2).fill()
    }
}

private final class OutlineCell: NSTableCellView {
    let chevron = NSButton()
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let size = NSTextField(labelWithString: "")
    /// Direct item count for folders; hidden when the sidebar is too narrow to keep names readable.
    let count = NSTextField(labelWithString: "")
    fileprivate let bar = ShareBarView()
    var depth = 0
    var hasChildren = false
    var onToggle: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        chevron.isBordered = false
        chevron.bezelStyle = .inline
        chevron.imagePosition = .imageOnly
        chevron.target = self
        chevron.action = #selector(toggle)
        chevron.setButtonType(.momentaryChange)
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: NSFont.systemFontSize)
        size.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        size.textColor = .secondaryLabelColor
        size.alignment = .right
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.textColor = .tertiaryLabelColor
        count.alignment = .right
        icon.imageScaling = .scaleProportionallyDown
        for v in [chevron, icon, name, size, count, bar] as [NSView] { addSubview(v) }
        textField = name
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle() { onToggle?() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { size.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor }
    }

    override func layout() {
        super.layout()
        let h = bounds.height, w = bounds.width
        // Indent is capped so deep rows keep a readable name in a narrow sidebar.
        let x0 = 8 + CGFloat(min(depth, 8)) * 10
        chevron.frame = NSRect(x: x0, y: (h - 14) / 2, width: 14, height: 14)
        chevron.isHidden = !hasChildren
        icon.frame = NSRect(x: x0 + 18, y: (h - 16) / 2, width: 16, height: 16)
        bar.frame = NSRect(x: w - 8 - 44, y: (h - 6) / 2, width: 44, height: 6)
        let sizeW: CGFloat = 70
        size.frame = NSRect(x: bar.frame.minX - 8 - sizeW, y: (h - 16) / 2, width: sizeW, height: 16)
        let showCount = w >= 400 && !count.stringValue.isEmpty
        count.isHidden = !showCount
        let countW: CGFloat = 84
        count.frame = NSRect(x: size.frame.minX - 6 - countW, y: (h - 14) / 2, width: countW, height: 14)
        let nx = x0 + 40
        let nameRight = showCount ? count.frame.minX : size.frame.minX
        name.frame = NSRect(x: nx, y: (h - 16) / 2, width: max(60, nameRight - 8 - nx), height: 16)
    }
}

private struct OutlineTable: NSViewRepresentable {
    let model: AppModel
    let tree: Tree
    let total: UInt64
    let revision: Int
    let selected: UInt32?

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyTable()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("outline"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = OutlineView.rowHeight
        table.style = .inset
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.setAccessibilityLabel("Folder outline")
        table.onKey = { [weak c = context.coordinator] code in c?.key(code) ?? false }
        table.contextRow = { [weak c = context.coordinator] r in c?.menu(for: r) }
        context.coordinator.table = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.tree = tree
        c.total = total
        if c.shownRevision != revision {
            c.shownRevision = revision
            c.table?.reloadData()
        }
        c.syncSelection(selected)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: AppModel
        weak var table: KeyTable?
        var tree: Tree?
        var total: UInt64 = 1
        var shownRevision = -1
        private var suppress = false
        init(_ m: AppModel) { model = m }

        func numberOfRows(in tableView: NSTableView) -> Int { model.outlineRows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tree, row < model.outlineRows.count else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? OutlineCell) ?? { let c = OutlineCell(frame: .zero); c.identifier = id; return c }()
            let r = model.outlineRows[row]
            let info = tree.info(r.node)
            let shown = model.activeFilter?.size(r.node) ?? info.size
            let isDir = info.kind == .directory
            let expanded = model.expanded.contains(r.node)
            cell.depth = Int(r.depth)
            cell.hasChildren = isDir && info.childCount > 0
            cell.chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: expanded ? "Collapse" : "Expand")?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            cell.icon.image = NSImage(systemSymbolName: Self.icon(info), accessibilityDescription: nil)
            cell.icon.contentTintColor = isDir ? .controlAccentColor : .secondaryLabelColor
            let nm = tree.name(r.node)
            cell.name.stringValue = nm
            cell.size.stringValue = formatBytes(shown)
            cell.count.stringValue = isDir ? "\(info.childCount.formatted()) item\(info.childCount == 1 ? "" : "s")" : ""
            cell.bar.fraction = Double(shown) / Double(max(1, total))
            let node = r.node
            cell.onToggle = { [weak self] in self?.model.toggle(node) }
            cell.setAccessibilityLabel("\(nm), \(isDir ? "folder" : "item"), \(formatBytes(shown))\(isDir ? ", \(info.childCount) items" : "")")
            cell.setAccessibilityValue(cell.hasChildren ? (expanded ? "expanded" : "collapsed") : nil)
            cell.needsLayout = true
            return cell
        }

        static func icon(_ i: NodeInfo) -> String {
            switch i.kind {
            case .directory: "folder"
            case .package: "app.gift"
            case .symlink: "link"
            case .file: "doc"
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppress, let t = table else { return }
            let r = t.selectedRow
            let node: UInt32? = r >= 0 && r < model.outlineRows.count ? model.outlineRows[r].node : nil
            if model.selected != node { model.selected = node }
        }

        /// Model -> table. O(1): dictionary lookup, then AppKit scrolls straight to the row.
        func syncSelection(_ node: UInt32?) {
            guard let t = table else { return }
            let idx = node.flatMap { model.outlineIndex[$0] }
            if let idx {
                if t.selectedRow != idx {
                    suppress = true
                    t.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                    suppress = false
                    t.scrollRowToVisible(idx)
                }
            } else if t.selectedRow >= 0 {
                suppress = true; t.deselectAll(nil); suppress = false
            }
        }

        func key(_ code: UInt16) -> Bool {
            guard let tree, let s = model.selected else { return false }
            let info = tree.info(s)
            let isDir = info.kind == .directory && info.childCount > 0
            switch code {
            case 124: if isDir && !model.expanded.contains(s) { model.toggle(s) }; return isDir      // right
            case 123: if isDir && model.expanded.contains(s) { model.toggle(s) }; return isDir       // left
            case 36, 76: model.drill(into: s); return true                                           // return, enter
            default: return false
            }
        }

        @objc func doubleClicked() {
            guard let t = table, t.clickedRow >= 0, t.clickedRow < model.outlineRows.count else { return }
            model.drill(into: model.outlineRows[t.clickedRow].node)
        }

        func menu(for row: Int) -> NSMenu? {
            guard row < model.outlineRows.count else { return nil }
            let node = model.outlineRows[row].node
            let m = NSMenu()
            let a = BlockItem(title: "Show in Finder") { [weak self] in self?.model.reveal(node) }
            let b = BlockItem(title: "Move to Trash…") { [weak self] in self?.model.proposeRemoval(of: node) }
            m.addItem(a); m.addItem(b)
            return m
        }
    }
}

private final class BlockItem: NSMenuItem {
    private let block: () -> Void
    init(title: String, block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { block() }
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
