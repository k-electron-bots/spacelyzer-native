import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.demoReduceMotion) private var demoReduceMotion
    private var reduceMotion: Bool { demoReduceMotion ?? systemReduceMotion }

    // Windows opened from the toolbar below; the states live on this view so the buttons
    // and their sheets stay in one struct.
    @State private var showExclusions = false
    @State private var showDuplicates = false
    @State private var showRemovalHistory = false

    var body: some View {
        @Bindable var model = model
        Group {
            if model.tree == nil && !model.scanning {
                WelcomeView()
            } else {
                NavigationSplitView {
                    OutlineView()
                        .safeAreaInset(edge: .top, spacing: 0) { FilterBar() }
                        .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 700)
                        .padding(.bottom, StatusBar.height)
                } detail: {
                    TrailingPane()
                        .frame(minWidth: 380)
                        .padding(.bottom, StatusBar.height)
                        .background(GeometryReader { g in
                            Color.clear.onChange(of: g.size, initial: true) { _, _ in LayoutProbe.log("detail", g) }
                        })
                }
            }
        }
        .transaction { if reduceMotion { $0.animation = nil } }
        .safeAreaInset(edge: .top, spacing: 0) { FullDiskAccessBanner() }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        .toolbar {
            ToolbarItemGroup {
                Button { model.up() } label: { Label("Up", systemImage: "arrow.up") }
                    .disabled(model.tree == nil || model.displayedRoot == 0)
                    .accessibilityLabel("Go to parent folder").help("Go to parent folder")
                Menu {
                    Button("Choose Folder…") { model.chooseFolder() }
                    Button("Startup Disk") { model.scanStartupVolume() }
                    Button("Home Folder") { model.scanHome() }
                    Button("Exclusions…") { showExclusions = true }
                    Button("Duplicates…") { showDuplicates = true }
                        .disabled(model.tree == nil)
                } label: { Label("Scan", systemImage: "externaldrive") }
                if model.scanning {
                    Button { model.cancel() } label: { Label("Stop", systemImage: "stop.circle") }
                        .accessibilityLabel("Stop scan").help("Stop the current scan")
                }
            }
            ToolbarItem {
                Button { model.exportLargestCSV() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                    .disabled(model.tab != .largest || model.largestExportBlockedReason != nil)
                    .help(model.tab != .largest ? "Open the Largest tab to export its list as CSV" : (model.largestExportBlockedReason ?? "Export the Largest list as CSV (read only, as the scan recorded it)"))
                    .accessibilityLabel("Export the Largest list as CSV")
            }
            ToolbarItem {
                Button { if let s = model.selected { model.proposeReview(of: s) } } label: { Label("Check on disk", systemImage: "doc.text.magnifyingglass") }
                    .disabled(model.selected == nil || model.selected == 0 || model.tree == nil)
                    .help("Compare the selected item with what the scan recorded (read only)")
                    .accessibilityLabel("Check the selected item on disk")
                    .popover(isPresented: Binding(get: { model.reviewItem != nil }, set: { if !$0 { model.reviewItem = nil } })) {
                        if let id = model.reviewItem, let t = model.tree {
                            ItemReviewPopover(model: model, tree: t, id: id, dismiss: { model.reviewItem = nil })
                        }
                    }
            }
            ToolbarItem {
                Button { showRemovalHistory = true } label: { Label("Removed", systemImage: "arrow.uturn.backward.circle") }
                    .disabled(model.lastRemoved.isEmpty)
                    .help("Items moved to the Trash this session, each with its own Put Back")
                    .accessibilityLabel("Removal history")
                    .popover(isPresented: $showRemovalHistory) {
                        RemovalHistoryPopover(model: model)
                    }
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $model.tab) {
                    Text("Treemap").tag(TrailingTab.treemap)
                    Text("Kinds").tag(TrailingTab.kinds)
                    Text("Largest").tag(TrailingTab.largest)
                    Text("Folders").tag(TrailingTab.folders)
                }.pickerStyle(.segmented)
            }
        }
        .alert("Move to Trash?", isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } })) {
            Button("Move to Trash", role: .destructive) { model.confirmRemoval() }
            Button("Cancel", role: .cancel) { model.pendingRemoval = nil }
        } message: {
            if let id = model.pendingRemoval, let t = model.tree {
                if let snap = model.nodeSnapshot(id) {
                    Text("\(snap.path)\n\(formatBytes(snap.info.size)). You can put it back right after.")
                } else {
                    Text("\(t.path(id))\nThe size is updating. You can put it back right after.")
                }
            }
        }
        .alert("Spacelyzer", isPresented: Binding(get: { model.removalMessage != nil }, set: { if !$0 { model.removalMessage = nil } })) {
            if !model.lastRemoved.isEmpty { Button("Undo") { model.undoRemoval() } }
            Button("OK", role: .cancel) {}
        } message: { Text(model.removalMessage ?? "") }
        .alert("Export", isPresented: Binding(get: { model.exportMessage != nil }, set: { if !$0 { model.exportMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.exportMessage ?? "") }
        .sheet(isPresented: $showExclusions) {
            ExclusionsView(exclusions: $model.exclusions, tree: model.tree)
        }
        .sheet(isPresented: $showDuplicates) {
            // Captured at presentation: the review reads one frozen pass from this tree.
            if let t = model.tree { DuplicatesReviewView(tree: t) }
        }
        .background(GeometryReader { geometry in
            Color.clear.onChange(of: geometry.size, initial: true) { _, size in
                if Perf.on { DemoRootLayout.size = size }
            }
        })
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.pie").font(.system(size: 54)).foregroundStyle(.secondary)
            Text("See what is using your disk").font(.title2.bold())
            Text("Everything stays on this Mac. Spacelyzer has no networking code.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Scan Startup Disk") { model.scanStartupVolume() }.buttonStyle(.borderedProminent)
                Button("Scan Home Folder") { model.scanHome() }
                Button("Choose Folder…") { model.chooseFolder() }
            }
            Text("Full Disk Access may improve access after relaunch; some protected locations remain unreadable.")
                .font(.caption).foregroundStyle(.tertiary)
            if let e = model.error { Text(e).foregroundStyle(.red) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusBar: View {
    var demoDetailsCaptured: ((String) -> Void)? = nil
    /// Measured on CI: NavigationSplitView columns extend to the window bottom (frame bottom = 612 = window height), under this bar.
    static let height: CGFloat = 26
    @Environment(AppModel.self) private var model
    @State private var showSkipped = false
    private var unreadable: Int { Perf.on ? (model.demoFooterUnreadable ?? model.tree?.skippedCount ?? 0) : (model.tree?.skippedCount ?? 0) }
    private var partial: Bool { Perf.on ? (model.demoFooterPartial ?? model.tree?.wasCancelled ?? false) : (model.tree?.wasCancelled ?? false) }
    var body: some View {
        HStack(spacing: 8) {
            if model.scanning { ProgressView().controlSize(.small) }
            Text(model.rootPath).truncationMode(.middle)
                .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
                .help(model.rootPath).accessibilityLabel("Scanned folder: \(model.rootPath)")
            ViewThatFits(in: .horizontal) {
                summary(compact: false).fixedSize(horizontal: true, vertical: false)
                summary(compact: true).fixedSize(horizontal: true, vertical: false)
            }
            .accessibilityElement(children: .combine)
            .help(fullDetails).accessibilityLabel(fullDetails)
            .layoutPriority(1)
        }
        .font(.caption).lineLimit(1).padding(.horizontal, 10)
        .frame(height: Self.height).background(.bar)
        .sheet(isPresented: $showSkipped) {
            // Captured at presentation: the skipped list is fixed when the scan ends, so
            // this tree's list stays consistent even if a newer scan starts underneath.
            if let t = model.tree { SkippedListView(tree: t) }
        }
        .onAppear { if Perf.on { demoDetailsCaptured?(fullDetails) } }
    }
    @ViewBuilder private func summary(compact: Bool) -> some View {
        HStack(spacing: compact ? 5 : 8) {
            if model.scanning {
                Text("Scanning · \(itemCount(model.progress.items)) · \(formatBytes(model.progress.bytes))")
            } else if let t = model.tree {
                Text("\((model.publishedTotalBytes.map(formatBytes) ?? "…")) in \(itemCount(UInt64(t.nodeCount - 1)))")
                if partial { Text(compact ? "Partial" : "Stopped early, partial").foregroundStyle(.orange) }
                if let f = model.activeFilter {
                    Text("Filter: \(formatBytes(f.totalBytes)) · \(fileCount(UInt64(f.totalCount)))").foregroundStyle(.blue)
                }
                if unreadable > 0 {
                    Button("\(locationCount(unreadable)) \(compact ? "unreadable" : "not readable")") { showSkipped = true }
                        .buttonStyle(.plain).foregroundStyle(.orange)
                        .help("Show the locations that were not scanned")
                }
                VolumeHeaderView(rootPath: model.rootPath)
            }
            if !compact {
                if model.scanning { Text("\(String(format: "%.1f", model.elapsed))s").foregroundStyle(.secondary) }
                else if let elapsed = model.lastScanSeconds { Text("Scanned in \(String(format: "%.2f", elapsed))s").foregroundStyle(.secondary) }
                if model.activeFilter != nil { Text("Filter \(String(format: "%.1f", model.filterMillis))ms").foregroundStyle(.secondary) }
            }
        }
    }
    private var fullDetails: String {
        var parts = [model.rootPath]
        if model.scanning {
            parts.append("Scanning: \(itemCount(model.progress.items)), \(formatBytes(model.progress.bytes)), \(String(format: "%.1f", model.elapsed)) seconds")
        } else if let t = model.tree {
            parts.append("\((model.publishedTotalBytes.map(formatBytes) ?? "…")) in \(itemCount(UInt64(t.nodeCount - 1)))")
            if partial { parts.append("Stopped early, partial accounting") }
            if let elapsed = model.lastScanSeconds { parts.append("Scanned in \(String(format: "%.2f", elapsed)) seconds") }
            if let f = model.activeFilter { parts.append("Filter: \(formatBytes(f.totalBytes)), \(fileCount(UInt64(f.totalCount))), \(String(format: "%.1f", model.filterMillis)) milliseconds") }
            if unreadable > 0 { parts.append("\(locationCount(unreadable)) not readable") }
        }
        return parts.joined(separator: "\n")
    }
    private func itemCount(_ count: UInt64) -> String { "\(count.formatted()) \(count == 1 ? "item" : "items")" }
    private func fileCount(_ count: UInt64) -> String { "\(count.formatted()) \(count == 1 ? "file" : "files")" }
    private func locationCount(_ count: Int) -> String { "\(count.formatted()) \(count == 1 ? "location" : "locations")" }

}


/// CI-only layout measurement (SPZ_DEMO): appends geometry and window metrics to /tmp/spz-geom.txt.
enum LayoutProbe {
    @MainActor static func log(_ tag: String, _ g: GeometryProxy) {
        guard ProcessInfo.processInfo.environment["SPZ_DEMO"] != nil else { return }
        let f = g.frame(in: .global)
        var line = "\(tag): frame=\(f) size=\(g.size) safe=\(g.safeAreaInsets)"
        if let w = NSApp.keyWindow ?? NSApp.windows.first {
            line += " window.frame=\(w.frame) contentLayoutRect=\(w.contentLayoutRect) contentView.frame=\(w.contentView?.frame ?? .zero)"
        }
        let url = URL(fileURLWithPath: "/tmp/spz-geom.txt")
        let data = (line + "\n").data(using: .utf8)!
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
    }
}


/// Always-visible filter row (name field plus kind and size menu) at the top of the outline.
struct FilterBar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            NameFilterField(model: model)
            TextField("ext", text: $model.filterExt).textFieldStyle(.plain).frame(width: 38)
                .help("File extension, for example pdf or mp4")
                .accessibilityLabel("Extension filter")
            if !model.filterText.isEmpty {
                Button { model.filterText = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Clear name filter").help("Clear name filter")
            }
            Menu {
                Picker("Kind", selection: $model.filterKind) {
                    Text("Any kind").tag(FileCategory?.none)
                    ForEach(FileCategory.allCases.filter { $0 != .folder }, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                Picker("Minimum size", selection: $model.filterMinMB) {
                    Text("Any size").tag(0)
                    ForEach([1, 10, 100, 1000], id: \.self) { Text("≥ \($0) MB").tag($0) }
                }
                Picker("Maximum size", selection: $model.filterMaxMB) {
                    Text("No maximum").tag(0)
                    ForEach([1, 10, 100, 1000], id: \.self) { Text("≤ \($0) MB").tag($0) }
                }
                Picker("Modified", selection: $model.filterModifiedDays) {
                    Text("Any time").tag(0)
                    Text("Last 7 days").tag(7)
                    Text("Last 30 days").tag(30)
                    Text("Last year").tag(365)
                }
                Divider()
                Button("Clear all filters") { model.clearFilters() }.disabled(!model.filterIsActive)
            } label: {
                Image(systemName: model.filterIsActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Filter by kind, size and modified date")
            .accessibilityLabel(model.filterIsActive ? "Filters, active" : "Filters")
            Menu {
                Picker("Sort folders by", selection: $model.outlineSort) {
                    ForEach(OutlineSort.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Sort order of the outline")
            .accessibilityLabel("Sort order")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .modifier(AdaptiveControlSurface())
        .padding(.horizontal, 10).padding(.bottom, 4)
        .disabled(model.tree == nil)
    }
}

/// One functional control surface. System controls keep their native appearance;
/// opaque fallback follows the live accessibility preference, not a startup snapshot.
private struct AdaptiveControlSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.demoReduceTransparency) private var demoReduceTransparency
    private var reduceTransparency: Bool { demoReduceTransparency ?? systemReduceTransparency }
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 6))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

// Optional overrides exist solely for SPZ_DEMO. nil always inherits live OS preferences.
private struct DemoReduceTransparencyKey: EnvironmentKey { static let defaultValue: Bool? = nil }
private struct DemoReduceMotionKey: EnvironmentKey { static let defaultValue: Bool? = nil }
extension EnvironmentValues {
    var demoReduceTransparency: Bool? {
        get { self[DemoReduceTransparencyKey.self] }
        set { self[DemoReduceTransparencyKey.self] = newValue }
    }
    var demoReduceMotion: Bool? {
        get { self[DemoReduceMotionKey.self] }
        set { self[DemoReduceMotionKey.self] = newValue }
    }
}

@MainActor enum DemoRootLayout { static var size: CGSize = .zero }

/// Native text entry keeps the key-view loop continuous with the AppKit outline.
private struct NameFilterField: NSViewRepresentable {
    let model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSTextField {
        let field = AttachedNameField()
        field.onAttachment = { [weak model] in model?.connectOutlineFocusLoop() }
        field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .default
        field.placeholderString = "Filter by name"
        field.setAccessibilityLabel("Filter by name")
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        model.nameFilterKeyView = field
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        _ = model.nameEditorRefreshRevision
        let target = model.filterText
        let editor = field.currentEditor() as? NSTextView
        // Capture external intent before cancellation can synchronously notify the delegate.
        // Editor text can diverge from field/model while composition is underway.
        let externalIntent = context.coordinator.externalRevision != model.externalFilterTextRevision || context.coordinator.resetRevision != model.filterResetRevision
        context.coordinator.externalRevision = model.externalFilterTextRevision
        context.coordinator.resetRevision = model.filterResetRevision
        let marked = editor?.hasMarkedText() ?? false
        if externalIntent || (!marked && (field.stringValue != target || (editor != nil && editor!.string != target))) {
            context.coordinator.programmaticChange = true
            defer { context.coordinator.programmaticChange = false }
            if let editor {
                let selection = editor.selectedRange()
                if editor.hasMarkedText() { editor.unmarkText() }
                editor.string = target
                let start = min(selection.location, target.utf16.count)
                editor.setSelectedRange(NSRange(location: start, length: min(selection.length, max(0, target.utf16.count - start))))
            }
            field.stringValue = target
        }
        model.nameFilterKeyView = field
        model.connectOutlineFocusLoop()
        if Perf.on {
            model.nameEditorConsumedReset = context.coordinator.resetRevision
            model.nameEditorUpdateCount &+= 1
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: AppModel
        var programmaticChange = false
        var externalRevision: UInt64
        var resetRevision: UInt64
        init(_ model: AppModel) {
            self.model = model
            externalRevision = model.externalFilterTextRevision
            resetRevision = model.filterResetRevision
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if Perf.on {
                let event = NSApp.currentEvent
                Perf.log("native-tab field-command=\(NSStringFromSelector(commandSelector)) code=\(event.map { String($0.keyCode) } ?? "none") modifiers=\(event.map { String($0.modifierFlags.rawValue) } ?? "none") chars=\(event?.characters?.debugDescription ?? "none") ignoring=\(event?.charactersIgnoringModifiers?.debugDescription ?? "none") editorMatches=\(control.window?.firstResponder === textView) delegateMatches=\(textView.delegate === control) responder=\(String(describing: control.window?.firstResponder))")
            }
            guard commandSelector == #selector(NSResponder.insertBacktab(_:)), !textView.hasMarkedText() else { return false }
            // Do not intercept modified shortcuts, or IME composition commands.
            if let event = NSApp.currentEvent, !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
            return model.focusOutlineFromName(control, editor: textView, modifiers: NSApp.currentEvent?.modifierFlags ?? []).consumesCommand
        }
        func controlTextDidChange(_ notification: Notification) {
            guard !programmaticChange, let field = notification.object as? NSTextField else { return }
            model.setFilterTextFromEditor(field.stringValue)
        }
    }
}

private final class AttachedNameField: NSTextField {
    var onAttachment: (() -> Void)?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onAttachment?() }
}
