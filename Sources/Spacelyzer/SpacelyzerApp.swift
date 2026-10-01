import SwiftUI

@main
struct SpacelyzerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Spacelyzer") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    // CI uses this to launch with a scan already running and take a screenshot.
                    let env = ProcessInfo.processInfo.environment
                    if let path = env["SPZ_AUTOSCAN"] { model.scan(path) }
                    // CI-only scripted interaction so screenshots can show expand, filter and kind views.
                    if env["SPZ_AUTOSCAN"] != nil, env["SPZ_DEMO"] != nil {
                        while model.scanning || model.tree == nil { try? await Task.sleep(nanoseconds: 500_000_000) }
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if let first = model.outlineRows.first?.node { model.toggle(first) }   // expand top folder
                        try? await Task.sleep(nanoseconds: 4_000_000_000)                        // screenshot A
                        model.filterKind = .video; model.filterMinMB = 1                         // filter
                        try? await Task.sleep(nanoseconds: 6_000_000_000)                        // screenshot B
                        model.filterKind = nil; model.filterMinMB = 0; model.filterText = "lib"
                        try? await Task.sleep(nanoseconds: 6_000_000_000)                        // screenshot C
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
