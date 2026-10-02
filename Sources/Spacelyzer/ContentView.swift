import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.demoReduceMotion) private var demoReduceMotion
    private var reduceMotion: Bool { demoReduceMotion ?? systemReduceMotion }

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
                } label: { Label("Scan", systemImage: "externaldrive") }
                if model.scanning {
                    Button { model.cancel() } label: { Label("Stop", systemImage: "stop.circle") }
                        .accessibilityLabel("Stop scan").help("Stop the current scan")
                }
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $model.tab) {
                    Text("Treemap").tag(TrailingTab.treemap)
                    Text("Kinds").tag(TrailingTab.kinds)
                    Text("Largest").tag(TrailingTab.largest)
                }.pickerStyle(.segmented)
            }
        }
        .alert("Move to Trash?", isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } })) {
            Button("Move to Trash", role: .destructive) { model.confirmRemoval() }
            Button("Cancel", role: .cancel) { model.pendingRemoval = nil }
        } message: {
            if let id = model.pendingRemoval, let t = model.tree {
                Text("\(t.path(id))\n\(formatBytes(t.info(id).size)). You can put it back right after.")
            }
        }
        .alert("Spacelyzer", isPresented: Binding(get: { model.removalMessage != nil }, set: { if !$0 { model.removalMessage = nil } })) {
            if !model.lastRemoved.isEmpty { Button("Undo") { model.undoRemoval() } }
            Button("OK", role: .cancel) {}
        } message: { Text(model.removalMessage ?? "") }
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
            Text("Tip: grant Full Disk Access in System Settings for a complete scan, then relaunch.")
                .font(.caption).foregroundStyle(.tertiary)
            if let e = model.error { Text(e).foregroundStyle(.red) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusBar: View {
    /// Measured on CI: NavigationSplitView columns extend to the window bottom (frame bottom = 612 = window height), under this bar.
    static let height: CGFloat = 26
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack {
            if model.scanning {
                ProgressView().controlSize(.small)
                Text("Scanning \(model.rootPath)  ·  \(model.progress.items.formatted()) items  ·  \(formatBytes(model.progress.bytes))  ·  \(String(format: "%.1f", model.elapsed))s")
            } else if let t = model.tree {
                let incomplete = t.wasCancelled ? " (stopped early, partial)" : ""
                Text("\(model.rootPath)  ·  \(formatBytes(t.info(0).size)) in \(spz_items(t)) items\(incomplete)")
                if let s = model.lastScanSeconds { Text("· scanned in \(String(format: "%.2f", s))s").foregroundStyle(.secondary) }
                if let f = model.activeFilter {
                    Text("· filter: \(formatBytes(f.totalBytes)) in \(f.totalCount.formatted()) files (\(String(format: "%.1f", model.filterMillis)) ms in Rust)").foregroundStyle(.blue)
                }
                let skipped = t.skipped.count
                if skipped > 0 { Text("· \(skipped) locations not readable").foregroundStyle(.orange) }
            }
            Spacer()
        }
        .font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
        .background(.bar)
    }
    private func spz_items(_ t: Tree) -> String { (t.nodeCount - 1).formatted() }
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
        if field.stringValue != model.filterText {
            if let editor = field.currentEditor() as? NSTextView {
                if editor.hasMarkedText() { return } // Never overwrite an unfinished IME composition.
                let selection = editor.selectedRange()
                editor.string = model.filterText
                editor.setSelectedRange(NSRange(location: min(selection.location, editor.string.utf16.count), length: min(selection.length, max(0, editor.string.utf16.count - min(selection.location, editor.string.utf16.count)))))
            }
            field.stringValue = model.filterText
        }
        model.nameFilterKeyView = field
        model.connectOutlineFocusLoop()
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: AppModel
        init(_ model: AppModel) { self.model = model }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.filterText = field.stringValue
        }
    }
}

private final class AttachedNameField: NSTextField {
    var onAttachment: (() -> Void)?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onAttachment?() }
}
