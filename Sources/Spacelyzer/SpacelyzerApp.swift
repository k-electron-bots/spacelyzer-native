import SwiftUI

@main
struct SpacelyzerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Spacelyzer") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
                .task {
                    // CI uses this to launch with a scan already running and take a screenshot.
                    let env = ProcessInfo.processInfo.environment
                    if let path = env["SPZ_AUTOSCAN"] { model.scan(path) }
                    // CI-only scripted interaction so screenshots can show expand, filter and kind views.
                    if env["SPZ_AUTOSCAN"] != nil, env["SPZ_DEMO"] != nil {
                        while model.scanning || model.tree == nil { try? await Task.sleep(nanoseconds: 500_000_000) }
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        func mark(_ n: Int) { try? "\(n)".write(toFile: "/tmp/spz-demo-step", atomically: true, encoding: .utf8) }
                        if let first = model.outlineRows.first?.node { model.toggle(first) }   // expand top folder
                        try? await Task.sleep(nanoseconds: 3_000_000_000); mark(1)               // CI shoots step 1
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        model.filterKind = .video; model.filterMinMB = 1
                        try? await Task.sleep(nanoseconds: 3_000_000_000); mark(2)
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        model.filterKind = nil; model.filterMinMB = 0; model.filterText = "lib"
                        try? await Task.sleep(nanoseconds: 3_000_000_000); mark(3)
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        model.filterText = ""; model.tab = .kinds
                        try? await Task.sleep(nanoseconds: 3_000_000_000); mark(4)
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        model.tab = .largest
                        if let n = model.outlineRows.dropFirst(2).first?.node { model.selected = n }
                        try? await Task.sleep(nanoseconds: 3_000_000_000); mark(5)
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        // Worst case for the outline: every folder expanded (all items become rows).
                        if let t = model.tree {
                            let t0 = Perf.now()
                            var all = Set<UInt32>()
                            for i in 0..<UInt32(t.nodeCount) where t.info(i).childCount > 0 { all.insert(i) }
                            Perf.log("expand-all: collect \(all.count) dirs via per-node FFI = \(String(format: "%.1f", Perf.ms(since: t0))) ms")
                            let t1 = Perf.now()
                            model.expanded = all
                            model.refreshOutline()
                            while model.outlineRows.count < 100_000 && Perf.ms(since: t1) < 20_000 { try? await Task.sleep(nanoseconds: 20_000_000) }
                            Perf.log("expand-all: rows=\(model.outlineRows.count) set-to-rows-on-main = \(String(format: "%.1f", Perf.ms(since: t1))) ms")
                        }
                        try? await Task.sleep(nanoseconds: 3_000_000_000); mark(6)
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Folder…") { model.chooseFolder() }.keyboardShortcut("o")
                Button("Scan Startup Disk") { model.scanStartupVolume() }
                Button("Scan Home Folder") { model.scanHome() }
            }
        }
    }
}
