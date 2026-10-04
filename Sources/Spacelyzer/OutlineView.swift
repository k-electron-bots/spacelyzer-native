import AppKit
import CSpacelyzer
import SwiftUI

/// The outline is an NSTableView: AppKit virtualizes rows and scrolls to a row in O(1), which a LazyVStack could not do
/// for 150k rows (profiled: scrollTo and row re-evaluation dominated every arrow press).
/// CI-only bounded causal envelope. Buffers instrumentation, not a CPU sampler.
@MainActor enum InteractionTrace {
    private struct Expected {
        let label: String
        let type: NSEvent.EventType
        let window: Int
        let timestamp: TimeInterval
        let code: UInt16?
        // Prospective diagnostic bins, not proof of AppKit's timestamp conversion mechanism.
        // A singleton normalized tuple is usable only within this bounded injected-event arm.
        func matches(_ e: NSEvent) -> Bool {
            guard let lhs = InteractionTrace.timestampBin(timestamp),
                  let rhs = InteractionTrace.timestampBin(e.timestamp) else { return false }
            return e.type == type && e.windowNumber == window && lhs == rhs &&
                   (code == nil || code == e.keyCode)
        }
    }
    private static var began: UInt64?
    private static var records: [(String, UInt64)] = []
    private static var dropped = 0
    private static var identityDropped = 0
    private static var collisions = 0
    private static var ambiguities = 0
    private static var invalidTimestamps = 0
    private static var normalizedLookups = 0
    private static var lastPosted = "none"
    private static var expected: [Expected] = []
    private static var label = "none"
    private static var phase = "none"
    private static var monitor: Any?
    private static var observer: CFRunLoopObserver?
    private static var generation = 0
    private static var wallBefore: TimeInterval = 0
    private static var wallAfter: TimeInterval = 0
    static var active: Bool { began != nil }
    static func begin(_ name: String = "click") {
        guard Perf.on else { return }
        if active { finish() }
        records = []; records.reserveCapacity(8192); expected = []; expected.reserveCapacity(41)
        dropped = 0; identityDropped = 0; collisions = 0; ambiguities = 0; invalidTimestamps = 0; normalizedLookups = 0; lastPosted = "none"; label = "none"; phase = name; generation += 1
        wallBefore = Date().timeIntervalSince1970; began = Perf.now(); wallAfter = Date().timeIntervalSince1970
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
            MainActor.assumeIsolated {
                label = identity(for: event)
                record("local-monitor-identity type=\(event.type.rawValue) window=\(event.windowNumber) eventTimestamp=\(event.timestamp) timestampBin_us=\(timestampBin(event.timestamp).map(String.init) ?? "invalid")")
            }
            return event // Do not consume, mutate or repost the event.
        }
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { _, activity in
            MainActor.assumeIsolated { record("runloop-activity=\(activity.rawValue)", attribution: "unattributed") }
        }
        if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
        record("trace-begin-before-window-lookup monitorInstalled=\(monitor != nil) observerInstalled=\(observer != nil)")
    }
    static func record(_ stage: String, attribution: String? = nil, stamp: UInt64? = nil) {
        guard began != nil else { return }
        guard records.count < 8192 else { dropped += 1; return }
        records.append(("event=\(attribution ?? label) \(stage)", stamp ?? Perf.now()))
    }
    nonisolated private static func timestampBin(_ timestamp: TimeInterval) -> Int64? {
        guard timestamp.isFinite, timestamp >= 0 else { return nil }
        let microseconds = (timestamp * 1_000_000).rounded()
        guard microseconds.isFinite, microseconds >= 0, microseconds < Double(Int64.max) else { return nil }
        return Int64(microseconds)
    }
    private static func identity(for event: NSEvent) -> String {
        guard timestampBin(event.timestamp) != nil else { invalidTimestamps += 1; return "invalid-timestamp" }
        let matches = expected.filter { $0.matches(event) }
        if matches.count == 1 {
            if matches[0].timestamp != event.timestamp { normalizedLookups += 1 }
            return matches[0].label
        }
        if matches.count > 1 { ambiguities += 1; return "ambiguous" }
        return "unmatched"
    }
    static func recordEvent(_ stage: String, _ event: NSEvent) {
        guard active else { return }
        record(stage, attribution: identity(for: event))
    }
    static func driverResumed(_ elapsed: Double, selectionChanged: Bool) {
        record("driver-poll-resume elapsed_ms=\(elapsed) selectionChanged=\(selectionChanged) timeout=\(!selectionChanged)", attribution: lastPosted)
    }
    static func willPost(_ event: NSEvent) {
        guard active else { return }
        guard timestampBin(event.timestamp) != nil else { invalidTimestamps += 1; lastPosted = "invalid-timestamp"; label = "invalid-timestamp"; record("invalid-post-timestamp"); return }
        guard expected.count < 41 else { identityDropped += 1; lastPosted = "identity-dropped"; label = "identity-dropped"; record("post-identity-cap-exceeded", attribution: "unattributed"); return }
        if expected.contains(where: { $0.matches(event) }) {
            collisions += 1
            record("duplicate-normalized-identity-tuple type=\(event.type.rawValue) window=\(event.windowNumber) eventTimestamp=\(event.timestamp)", attribution: "ambiguous")
        }
        label = "\(phase)-\(expected.count)"
        lastPosted = label
        expected.append(Expected(label: label, type: event.type, window: event.windowNumber, timestamp: event.timestamp,
                                 code: event.type == .keyDown ? event.keyCode : nil))
        record("post-before type=\(event.type.rawValue) window=\(event.windowNumber) eventTimestamp=\(event.timestamp) timestampBin_us=\(timestampBin(event.timestamp).map(String.init) ?? "invalid")")
        let queued = Perf.now(), token = generation, identity = label
        record("probe-enqueued-before-post main-queue-opportunity-not-dispatch-latency", attribution: identity, stamp: queued)
        DispatchQueue.main.async {
            guard active, generation == token else { return }
            record("probe-executed enqueue_ns=\(queued)", attribution: identity)
        }
    }
    static func finish() {
        guard let start = began else { return }
        record("trace-finish")
        let complete = monitor != nil && observer != nil && dropped == 0 && identityDropped == 0 && collisions == 0 && ambiguities == 0 && invalidTimestamps == 0
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes); CFRunLoopObserverInvalidate(observer) }; observer = nil
        began = nil; generation += 1
        var lines = ["interaction-clock phase=\(phase) pid=\(ProcessInfo.processInfo.processIdentifier) uptime_ns=\(start) wall_before_unix=\(wallBefore) wall_after_unix=\(wallAfter) records=\(records.count) cap=8192 dropped=\(dropped) expectedEvents=\(expected.count) identityDropped=\(identityDropped) collisions=\(collisions) ambiguousLookups=\(ambiguities) invalidTimestamps=\(invalidTimestamps) normalizedLookups=\(normalizedLookups) identityScheme=type/window/rounded-microsecond/keycode instrumentationStatus=\(complete ? "NO-RECORDED-LOSS-WITH-LIMITS" : "INCOMPLETE-INCONCLUSIVE") cleanupMonitor=\(monitor == nil) cleanupObserver=\(observer == nil) arm=chronology-requested-settle-1s altered-idle=true no-cold-comparability sampleCoverage=UNVERIFIED-REQUIRES-PHASE-BRIDGE",
                     "limits: prospective rounded-microsecond singleton tuple, not raw exact timestamp identity or timestamp-mechanism proof; nearby timestamps can split across bin boundaries and stay unmatched, no nearest-neighbor rescue; different raw timestamps in same bin match by design, unrelated inbound event with same tuple is indistinguishable, no general event identity; all normalized-bin collisions invalidate whole phase including earlier records; monitor excludes nested event-tracking loops; model/view context label is most recent posted-or-monitored event, not causal proof; runloop common-modes only, not all nested loops; stamps unattributed/order0, other observers may run afterward; probe queued before post measures main-queue opportunity, not event dispatch latency; queue delay/runloop stamps are not CPU-busy proof; phase clock bridges separate, raw sampler overlap must be checked separately for click and arrows; flush before MainStall summaries is included, not clean benchmark; status only reports install/counter completeness, not matched delivery or selection causality; missing per-ID post/monitor/handler/model/driver stages require runtime coverage inspection even with zero drops; any cap/drop/collision/ambiguous identity invalidates whole-phase causal attribution, including earlier records; instrumentation/profiler/existing product log perturbation retained"]
        for (stage, stamp) in records { lines.append("interaction-stage \(stage) uptime_ns=\(stamp) elapsed_ms=\(Double(stamp - start) / 1e6)") }
        let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
        let url = URL(fileURLWithPath: "/tmp/spz-interaction-envelope.txt")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
        // Original timing stream keeps the bounded summary, not thousands of stage lines.
        Perf.log(lines[0]); records = []; expected = []; label = "none"
    }
}

struct OutlineView: View {
    @Environment(AppModel.self) private var model
    static let rowHeight: CGFloat = 28

    var body: some View {
        if let tree = model.tree {
            let total = max(1, model.outlineRootSize)   // same publication and table version as the rows
            OutlineTable(model: model, tree: tree, total: total, revision: model.outlineRevision, selected: model.selected, poisoned: model.enginePoisoned)
                .overlay {
                    if model.activeFilter != nil && model.outlineRows.isEmpty {
                        ContentUnavailableView("No matches", systemImage: "line.3.horizontal.decrease.circle",
                                               description: Text("Nothing in this folder matches the current filter."))
                    }
                }
                .onAppear { model.refreshOutline() }
                .onChange(of: model.selected) { _, n in
                    InteractionTrace.record("swiftui-selection-onChange-enter")
                    if let n { model.revealInOutline(n) }
                    InteractionTrace.record("swiftui-selection-onChange-exit")
                    guard Perf.on else { return }
                    let idx = n.flatMap { model.outlineIndex[$0] }
                    if InteractionTrace.active { InteractionTrace.record("selection-observed node=\(n.map(String.init) ?? "nil") rowIndex=\(idx.map(String.init) ?? "none")"); return }
                    Perf.log("selection changed: node=\(n.map(String.init) ?? "nil") rowIndex=\(idx.map(String.init) ?? "none") of \(model.outlineRows.count)")
                }
        } else {
            ProgressView("Scanning…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private final class KeyTable: NSTableView {
    var onAttachment: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        InteractionTrace.recordEvent("table-mouseDown-enter", event)
        super.mouseDown(with: event)
        InteractionTrace.recordEvent("table-mouseDown-exit", event)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onAttachment?() }
    var onTab: ((NSEvent.ModifierFlags) -> Bool)?
    var onKey: ((UInt16) -> Bool)?
    var contextRow: ((Int) -> NSMenu?)?
    private func tabDiagnostic(_ stage: String, _ event: NSEvent? = nil) {
        guard Perf.on else { return }
        Perf.log("native-tab \(stage) code=\(event.map { String($0.keyCode) } ?? "none") modifiers=\(event.map { String($0.modifierFlags.rawValue) } ?? "none") nextRaw=\(String(describing: nextKeyView)) responder=\(String(describing: window?.firstResponder))")
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 48 { tabDiagnostic("keyEquivalent-entry", event) }
        let handled = super.performKeyEquivalent(with: event)
        if event.keyCode == 48 { tabDiagnostic("keyEquivalent-exit-handled=\(handled)", event) }
        return handled
    }
    override func insertTab(_ sender: Any?) {
        tabDiagnostic("insertTab-entry")
        super.insertTab(sender)
        tabDiagnostic("insertTab-exit")
    }
    override func insertBacktab(_ sender: Any?) {
        tabDiagnostic("insertBacktab-entry")
        super.insertBacktab(sender)
        tabDiagnostic("insertBacktab-exit")
    }
    override func keyDown(with event: NSEvent) {
        InteractionTrace.recordEvent("table-keyDown-enter code=\(event.keyCode)", event)
        defer { InteractionTrace.recordEvent("table-keyDown-exit code=\(event.keyCode)", event) }
        if event.keyCode == 48 { tabDiagnostic("keyDown-entry", event) }
        if event.keyCode == 48 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            // Only the forward outline-to-filter boundary is explicit. Backward stays native.
            if !event.modifierFlags.contains(.shift), onTab?(event.modifierFlags) == true {
                tabDiagnostic("after-explicit-boundary", event)
                return
            }
            tabDiagnostic("native-fallback", event)
        }
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
    /// CI-only optional override; nil follows native live accessibility preferences.
    var contrastOverride: Bool? { didSet { updateTextColors() } }
    private var increasedContrast: Bool { contrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

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
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        icon.imageScaling = .scaleProportionallyDown
        for v in [chevron, icon, name, size, count, bar] as [NSView] { addSubview(v) }
        textField = name
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityOptionsChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        updateTextColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle() { onToggle?() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTextColors() }
    }
    @objc private func accessibilityOptionsChanged() { updateTextColors() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTextColors()
    }
    private func updateTextColors() {
        let selected = backgroundStyle == .emphasized
        let text: NSColor = selected ? .alternateSelectedControlTextColor : (increasedContrast ? .labelColor : .secondaryLabelColor)
        size.textColor = text
        count.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        name.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
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
        name.frame = NSRect(x: nx, y: (h - 16) / 2, width: max(0, nameRight - 8 - nx), height: 16)
    }
}

/// Test-binary-only switch: lets CI run the SAME binary with the poison repaint disabled, to show the poison checks fail without it.
/// In the shipped build this is constant true.
private enum PoisonReloadSwitch {
    static var enabled: Bool {
        #if SPZ_CI_TESTS
        return ProcessInfo.processInfo.environment["SPZ_CI_DISABLE_POISON_RELOAD"] == nil
        #else
        return true
        #endif
    }
}

private struct OutlineTable: NSViewRepresentable {
    let model: AppModel
    let tree: Tree
    let total: UInt64
    let revision: Int
    let selected: UInt32?
    let poisoned: Bool   // a latched engine panic must repaint visible cells, not wait for the next row publication

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
        table.onTab = { [weak model, weak table] modifiers in
            guard let table else { return false }
            return model?.focusNameFromOutline(table, modifiers: modifiers).consumesCommand ?? false
        }
        table.onKey = { [weak c = context.coordinator] code in c?.key(code) ?? false }
        table.contextRow = { [weak c = context.coordinator] r in c?.menu(for: r) }
        context.coordinator.table = table
        model.outlineKeyView = table
        table.onAttachment = { [weak model] in model?.connectOutlineFocusLoop() }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        InteractionTrace.record("outline-update-enter")
        defer { InteractionTrace.record("outline-update-exit") }
        let c = context.coordinator
        c.tree = tree
        model.outlineKeyView = c.table
        model.connectOutlineFocusLoop()
        c.total = total
        let poisonReload: Bool = PoisonReloadSwitch.enabled && c.shownPoisoned != poisoned
        if c.shownRevision != revision || poisonReload {
            c.shownRevision = revision
            c.shownPoisoned = poisoned
            c.table?.reloadData()
        }
        c.syncSelection(selected)
        if let table = c.table {
            let visible = table.rows(in: table.visibleRect)
            if visible.location != NSNotFound {
                for row in visible.location..<min(table.numberOfRows, NSMaxRange(visible)) {
                    (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? OutlineCell)?.contrastOverride = Perf.on ? model.demoIncreaseContrast : nil
                }
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: AppModel
        weak var table: KeyTable?
        var tree: Tree?
        var total: UInt64 = 1
        var shownRevision = -1
        var shownPoisoned = false
        private var suppress = false
        init(_ m: AppModel) { model = m }

        func numberOfRows(in tableView: NSTableView) -> Int { model.outlineRows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tree, row < model.outlineRows.count, row < model.outlineInfos.count, row < model.outlineShown.count else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? OutlineCell) ?? { let c = OutlineCell(frame: .zero); c.identifier = id; return c }()
            let r = model.outlineRows[row]
            let info = model.outlineInfos[row]   // published with the rows, never read live from the engine
            let shown = row < model.outlineShown.count ? model.outlineShown[row] : info.size   // same snapshot as the row, no live filter read
            let isDir = info.kind == .directory
            let expanded = model.expanded.contains(r.node)
            cell.depth = Int(r.depth)
            cell.hasChildren = isDir && info.childCount > 0
            cell.chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: expanded ? "Collapse" : "Expand")?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            cell.icon.image = NSImage(systemSymbolName: Self.icon(info), accessibilityDescription: nil)
            cell.icon.contentTintColor = isDir ? .controlAccentColor : .secondaryLabelColor
            // A caught engine panic makes the legacy name/path reads untrustworthy (they fall back to blank): show it, not a blank.
            let poisoned = model.enginePoisoned
            let nm = poisoned ? "Unavailable" : tree.name(r.node)
            cell.name.stringValue = nm
            let path = poisoned ? "" : tree.path(r.node)
            cell.name.toolTip = path
            cell.toolTip = path
            cell.contrastOverride = Perf.on ? model.demoIncreaseContrast : nil
            cell.size.stringValue = formatBytes(shown)
            cell.count.stringValue = isDir ? "\(info.childCount.formatted()) item\(info.childCount == 1 ? "" : "s")" : ""
            cell.bar.fraction = Double(shown) / Double(max(1, total))
            let node = r.node
            cell.onToggle = { [weak self] in self?.model.toggle(node) }
            cell.chevron.setAccessibilityLabel("\(expanded ? "Collapse" : "Expand") \(nm)")
            cell.chevron.setAccessibilityHelp("Show or hide this folder's children")
            cell.bar.setAccessibilityElement(false)
            cell.icon.setAccessibilityElement(false)
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
            InteractionTrace.record("native-selection-callback-enter")
            defer { InteractionTrace.record("native-selection-callback-exit") }
            guard !suppress, let t = table else { return }
            let r = t.selectedRow
            let node: UInt32? = r >= 0 && r < model.outlineRows.count ? model.outlineRows[r].node : nil
            if model.selected != node { InteractionTrace.record("model-selection-assign-begin"); model.selected = node; InteractionTrace.record("model-selection-assign-end") }
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
            // Node kind and child count come from the published outline snapshot (same capture as the rows), not a live read.
            guard !model.navigationBlocked, let s = model.selected, let idx = model.outlineIndex[s], idx < model.outlineInfos.count else { return false }
            let info = model.outlineInfos[idx]
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

/// CI inspection uses the same live cells and width threshold as the outline, not a containing hosting table.
@MainActor enum OutlineDemoEvidence {
    static var table: NSTableView? {
        DemoInput.allViews(of: NSTableView.self).first { $0.tableColumns.first?.identifier.rawValue == "outline" }
    }
    static var width: CGFloat { table?.view(atColumn: 0, row: 0, makeIfNecessary: true)?.bounds.width ?? 0 }
    static func countsVisible(_ visible: Bool) -> Bool {
        guard let table, table.numberOfRows > 0 else { return false }
        let cells = (0..<min(table.numberOfRows, 40)).compactMap { table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? OutlineCell }
        cells.forEach { $0.layoutSubtreeIfNeeded() }
        let folders = cells.filter { !$0.count.stringValue.isEmpty }
        return !folders.isEmpty && folders.allSatisfy {
            $0.count.isHidden == !visible && $0.name.frame.maxX + 4 <= (visible ? $0.count.frame.minX : $0.size.frame.minX)
        }
    }
    static var accessibleFolderLabels: Bool {
        guard let table else { return false }
        let cells = (0..<min(table.numberOfRows, 20)).compactMap { table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? OutlineCell }
        let folders = cells.filter { !$0.count.stringValue.isEmpty }
        return !folders.isEmpty && folders.allSatisfy {
            ($0.accessibilityLabel() ?? "").contains("folder") && (!$0.hasChildren || !($0.chevron.accessibilityLabel() ?? "").isEmpty)
                && !$0.bar.isAccessibilityElement() && !$0.icon.isAccessibilityElement()
        }
    }
    static func countColorContract(increased: Bool) -> Bool {
        guard let table else { return false }
        let range = table.rows(in: table.visibleRect)
        guard range.location != NSNotFound else { return false }
        let cells = (range.location..<min(table.numberOfRows, NSMaxRange(range))).compactMap {
            table.view(atColumn: 0, row: $0, makeIfNecessary: false) as? OutlineCell
        }.filter { !$0.count.stringValue.isEmpty && !$0.count.isHidden }
        let selected = cells.filter { $0.backgroundStyle == .emphasized }
        let other = cells.filter { $0.backgroundStyle != .emphasized }
        // The color-identity check is policy/branch evidence, not rendered contrast proof.
        let policy = !selected.isEmpty && !other.isEmpty
            && selected.allSatisfy { $0.count.textColor == .alternateSelectedControlTextColor }
            && other.allSatisfy { $0.count.textColor == .labelColor }
        for cell in cells {
            cell.effectiveAppearance.performAsCurrentDrawingAppearance {
                let fg = cell.count.textColor?.usingColorSpace(.sRGB)
                let bg = (cell.backgroundStyle == .emphasized ? NSColor.selectedContentBackgroundColor : NSColor.controlBackgroundColor).usingColorSpace(.sRGB)
                if let fg, let bg {
                    func luminance(_ c: NSColor) -> Double {
                        func linear(_ v: CGFloat) -> Double { let x = Double(v); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
                        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
                    }
                    let alpha = fg.alphaComponent
                    let blended = NSColor(srgbRed: fg.redComponent * alpha + bg.redComponent * (1-alpha), green: fg.greenComponent * alpha + bg.greenComponent * (1-alpha), blue: fg.blueComponent * alpha + bg.blueComponent * (1-alpha), alpha: 1)
                    let a = luminance(blended), b = luminance(bg)
                    Perf.log("count semantic-color contrast=\((max(a,b)+0.05)/(min(a,b)+0.05)) selected=\(cell.backgroundStyle == .emphasized) increased=\(increased) alpha=\(fg.alphaComponent); background proxy, inspect pixels")
                }
            }
        }
        return policy
    }
    static var selectionDiagnostic: String {
        guard let table else { return "table missing" }
        let cell = table.selectedRow >= 0 ? table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: false) as? OutlineCell : nil
        return "key=\(table.window?.isKeyWindow ?? false) firstResponder=\(String(describing: table.window?.firstResponder)) selectedRow=\(table.selectedRow) backgroundStyle=\(String(describing: cell?.backgroundStyle)) countColor=\(String(describing: cell?.count.textColor))"
    }
    static var inactiveSelectedCountPolicy: Bool {
        guard let table, let window = table.window, !window.isKeyWindow, table.selectedRow >= 0,
              let cell = table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: false) as? OutlineCell else { return false }
        return cell.backgroundStyle != .emphasized && cell.count.textColor == .labelColor
    }
    static var hasVisibleDeepRow: Bool {
        guard let table else { return false }
        let range = table.rows(in: table.visibleRect)
        guard range.location != NSNotFound else { return false }
        return (range.location..<min(table.numberOfRows, NSMaxRange(range))).contains {
            ((table.view(atColumn: 0, row: $0, makeIfNecessary: false) as? OutlineCell)?.depth ?? 0) >= 12
        }
    }
    static var hasVisibleDeepCount: Bool {
        guard let table else { return false }
        let range = table.rows(in: table.visibleRect)
        guard range.location != NSNotFound else { return false }
        return (range.location..<min(table.numberOfRows, NSMaxRange(range))).contains {
            guard let cell = table.view(atColumn: 0, row: $0, makeIfNecessary: false) as? OutlineCell else { return false }
            cell.layoutSubtreeIfNeeded()
            return cell.depth >= 12 && !cell.count.stringValue.isEmpty && !cell.count.isHidden
                && cell.name.frame.width > 0 && cell.name.frame.maxX + 4 <= cell.count.frame.minX
        }
    }
    static func hasCount(_ text: String) -> Bool {
        guard let table else { return false }
        return (0..<min(table.numberOfRows, 40)).contains {
            guard let cell = table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? OutlineCell else { return false }
            return cell.count.stringValue == text && !cell.count.isHidden
        }
    }
}
