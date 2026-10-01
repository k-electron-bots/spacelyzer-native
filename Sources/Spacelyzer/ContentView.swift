import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.tree == nil && !model.scanning {
                WelcomeView()
            } else {
                HSplitView {
                    OutlineView()
                        .frame(minWidth: 320, idealWidth: 420)
                    TrailingPane()
                        .frame(minWidth: 380)
                }
            }
        }
        .searchable(text: $model.filterText, placement: .toolbar, prompt: "Filter by name")
        .toolbar {
            ToolbarItemGroup {
                Button { model.up() } label: { Label("Up", systemImage: "arrow.up") }
                    .disabled(model.tree == nil || model.displayedRoot == 0)
                Menu {
                    Button("Choose Folder…") { model.chooseFolder() }
                    Button("Startup Disk") { model.scanStartupVolume() }
                    Button("Home Folder") { model.scanHome() }
                } label: { Label("Scan", systemImage: "externaldrive") }
                if model.scanning {
                    Button { model.cancel() } label: { Label("Stop", systemImage: "stop.circle") }
                }
            }
            ToolbarItem {
                Menu {
                    Picker("Kind", selection: $model.filterKind) {
                        Text("Any kind").tag(FileCategory?.none)
                        ForEach(FileCategory.allCases.filter { $0 != .folder }, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }
                    Picker("Minimum size", selection: $model.filterMinMB) {
                        Text("Any size").tag(0)
                        ForEach([1, 10, 100, 1000], id: \.self) { Text("≥ \($0) MB").tag($0) }
                    }
                } label: { Label("Filter", systemImage: model.filterIsActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
                .disabled(model.tree == nil)
            }
            ToolbarItem {
                Picker("View", selection: $model.tab) {
                    Text("Treemap").tag(TrailingTab.treemap)
                    Text("Kinds").tag(TrailingTab.kinds)
                    Text("Largest").tag(TrailingTab.largest)
                }.pickerStyle(.segmented)
            }
        }
        .safeAreaInset(edge: .bottom) { StatusBar() }
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
