import SwiftUI

@main
struct SpacelyzerApp: App {
    @State private var model = AppModel()
    @State private var demoReduceTransparency = false
    @State private var demoReduceMotion = false

    var body: some Scene {
        WindowGroup("Spacelyzer") {
            ContentView()
                .environment(model)
                .modifier(DemoAccessibilityModes(reduceTransparency: demoReduceTransparency, reduceMotion: demoReduceMotion))
                .frame(minWidth: 960, minHeight: 600)
                .task {
                    // CI uses this to launch with a scan already running and take a screenshot.
                    let env = ProcessInfo.processInfo.environment
                    if let path = env["SPZ_AUTOSCAN"] { model.scan(path) }
                    // CI-only scripted interaction so screenshots can show expand, filter and kind views.
                    if env["SPZ_AUTOSCAN"] != nil, env["SPZ_DEMO"] != nil {
                        while model.scanning || model.tree == nil { try? await Task.sleep(nanoseconds: 500_000_000) }
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        await PublicationRegression.run(tree: model.tree!)
                        await ZeroMatchRegression.run()
                        MainStall.shared.start()
                        func mark(_ n: Int) {
                            // CI-only handshake: the runner owns screen-capture permission.
                            // State cannot advance until that exact state was captured (or failed).
                            let ready = "/tmp/spz-demo-ready-\(n)", ack = "/tmp/spz-demo-ack-\(n)"
                            try? "\(n)".write(toFile: "/tmp/spz-demo-step", atomically: true, encoding: .utf8)
                            try? Data().write(to: URL(fileURLWithPath: ready))
                            let deadline = Date().addingTimeInterval(30)
                            while !FileManager.default.fileExists(atPath: ack) && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                            if !FileManager.default.fileExists(atPath: ack) { Perf.log("DEMO CAPTURE ACK TIMEOUT step=\(n)") }
                        }
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
                            MainStall.shared.reset()
                            model.expanded = all
                            model.refreshOutline()
                            while model.outlineRows.count < 100_000 && Perf.ms(since: t1) < 20_000 { try? await Task.sleep(nanoseconds: 20_000_000) }
                            Perf.log(MainStall.shared.summary("expand-all"))
                            Perf.log("expand-all: rows=\(model.outlineRows.count) set-to-rows-on-main = \(String(format: "%.1f", Perf.ms(since: t1))) ms")
                        }
                        try? await Task.sleep(nanoseconds: 3_000_000_000); mark(6)
                        // Step 7: selection set from outside the outline (as a treemap click would) must scroll into view.
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        MainStall.shared.reset()
                        if model.outlineRows.count > 5000 { model.selected = model.outlineRows[5000].node }
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        Perf.log(MainStall.shared.summary("far-jump-to-row-5000"))
                        mark(7)
                        // Steps 8-9: in-process NSEvents through the window's responder chain (no OS input permission needed).
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        MainStall.shared.reset()
                        let clickBefore = model.selected, clickT0 = Perf.now()
                        DemoInput.click(fromTop: 124, x: 168)                       // a visible outline row
                        while model.selected == clickBefore && Perf.ms(since: clickT0) < 5000 { try? await Task.sleep(nanoseconds: 1_000_000) }
                        Perf.log("click-latency (post -> selection changed): \(String(format: "%.1f", Perf.ms(since: clickT0))) ms")
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        Perf.log(MainStall.shared.summary("click-only"))
                        MainStall.shared.reset()
                        Perf.log("kbd: after click selected=\(model.selected.map(String.init) ?? "nil")")
                        let idx0 = model.selected.flatMap { n in model.outlineRows.firstIndex { $0.node == n } }
                        Check.expect("click-selects-a-row", idx0 != nil)
                        // Per-key latency: post the key, wait (1 ms polls) until the selection actually changes.
                        var lat: [Double] = []
                        for _ in 0..<40 {
                            let before = model.selected, t0 = Perf.now()
                            DemoInput.key(125)
                            while model.selected == before && Perf.ms(since: t0) < 3000 { try? await Task.sleep(nanoseconds: 1_000_000) }
                            lat.append(Perf.ms(since: t0))
                            try? await Task.sleep(nanoseconds: 30_000_000)
                        }
                        let sorted = lat.sorted()
                        Perf.log("key-latency 40 down arrows (post -> selection changed, ms): p50=\(String(format: "%.1f", sorted[20])) p95=\(String(format: "%.1f", sorted[37])) max=\(String(format: "%.1f", sorted[39])) first=\(String(format: "%.1f", lat[0]))")
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        Perf.log("kbd: after 40 down arrows selected=\(model.selected.map(String.init) ?? "nil")")
                        let idx1 = model.selected.flatMap { n in model.outlineRows.firstIndex { $0.node == n } }
                        Check.expect("40-down-arrows-move-40-rows", idx0 != nil && idx1 == idx0.map { $0 + 40 }, "from=\(idx0 ?? -1) to=\(idx1 ?? -1)")
                        Perf.log(MainStall.shared.summary("40-arrows-only"))
                        mark(8)
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        let before = model.selected
                        MainStall.shared.reset()
                        Perf.log("kbd: step 9 begin, clicking filter field")
                        DemoInput.click(fromTop: 65, x: 148)                        // filter field
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        Perf.log("kbd: filter field clicked")
                        for c in "lib" { DemoInput.key(0, chars: String(c)) }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        for _ in 0..<5 { DemoInput.key(125); try? await Task.sleep(nanoseconds: 50_000_000) }
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        Perf.log(MainStall.shared.summary("typing+arrows-in-filter"))
                        Check.expect("arrows-in-filter-field-do-not-move-selection", model.filterText == "lib" && model.selected == before, "text=\(model.filterText)")
                        Perf.log("kbd: filterText='\(model.filterText)' selection before=\(before.map(String.init) ?? "nil") after5arrows=\(model.selected.map(String.init) ?? "nil")")
                        mark(9)
                        // Step 10: no-matches state from the model (independent of event injection).
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        model.filterText = "zzzqqq"
                        try? await Task.sleep(nanoseconds: 3_000_000_000); mark(10)
                        // Step 11: removal guards, with the Trash operation mocked (nothing on disk is touched).
                        let realTrash = model.trashItem
                        var calls = 0
                        model.trashItem = { url in calls += 1; return url }
                        func settle() async { try? await Task.sleep(nanoseconds: 1_500_000_000) }
                        let victim: UInt32 = 67
                        model.selected = victim; model.removalMessage = nil; model.pendingRemoval = nil
                        await settle()   // filter 'zzzqqq' is active: victim is outside it
                        model.proposeRemoval(of: victim)
                        Perf.log("guardA propose-outside-filter pending=\(model.pendingRemoval != nil) message=\(model.removalMessage != nil) trashCalls=\(calls) expect pending=false message=true calls=0")
                        Check.expect("propose-outside-filter-is-refused", model.pendingRemoval == nil && model.removalMessage != nil && calls == 0)
                        model.removalMessage = nil
                        model.filterText = ""; await settle()
                        model.proposeRemoval(of: victim)
                        Perf.log("guardB1 propose-no-filter pending=\(model.pendingRemoval != nil) trashCalls=\(calls) expect pending=true calls=0")
                        Check.expect("propose-with-no-filter-opens-confirmation", model.pendingRemoval != nil && calls == 0)
                        model.filterText = "zzzqqq"; await settle()   // filter changes while the confirmation is open
                        model.confirmRemoval()
                        Perf.log("guardB2 confirm-after-filter-hid-it pending=\(model.pendingRemoval != nil) message=\(model.removalMessage != nil) trashCalls=\(calls) expect pending=false message=true calls=0")
                        Check.expect("confirm-after-filter-hid-it-trashes-nothing", model.pendingRemoval == nil && model.removalMessage != nil && calls == 0)
                        model.removalMessage = nil
                        model.filterText = ""; await settle()
                        model.proposeRemoval(of: victim); model.confirmRemoval()
                        Perf.log("guardC control-no-filter-mocked trashCalls=\(calls) expect calls=1 proves-mock-wired")
                        Check.expect("control-unfiltered-confirm-reaches-mock-once", calls == 1, "calls=\(calls)")
                        model.removalMessage = nil
                        // Typing-race checks: act in the same turn as the filter input changes, before its result lands.
                        let calls0 = calls
                        let victim2: UInt32 = 29554
                        model.filterText = ""; await settle(); model.removalMessage = nil
                        model.filterText = "zzzqqq"
                        model.proposeRemoval(of: victim2)
                        Check.expect("propose-right-after-typing-is-refused", model.filterPending && model.pendingRemoval == nil && calls == calls0, "pending=\(model.filterPending)")
                        await settle(); model.filterText = ""; await settle(); model.removalMessage = nil
                        model.proposeRemoval(of: victim2)
                        let opened = model.pendingRemoval != nil
                        model.filterText = "lib"
                        model.confirmRemoval()
                        Check.expect("confirm-right-after-typing-trashes-nothing", opened && model.filterPending && calls == calls0, "opened=\(opened)")
                        model.removalMessage = nil
                        model.filterText = "zzzqqq"; model.selected = model.outlineRows.first?.node ?? 1
                        await settle(); mark(11)
                        // Step 12: pointer sweep across the treemap (synthetic mouseMoved events), measuring main-thread stalls.
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        model.filterText = ""; model.displayedRoot = 0; model.tab = .treemap; await settle()
                        MainStall.shared.reset()
                        for i in 0..<300 {
                            DemoInput.move(fromTop: 140 + CGFloat(i % 60) * 6, x: 460 + CGFloat(i) * 1.6)
                            try? await Task.sleep(nanoseconds: 10_000_000)
                        }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        Perf.log(MainStall.shared.summary("hover-sweep-300-moves"))
                        Check.expect("hover-sweep-main-stall-under-250ms", MainStall.shared.peak < 250, "max=\(String(format: "%.1f", MainStall.shared.peak))ms")
                        mark(12)
                        // Step 12: Right/Left expand and collapse, Return drills (real key events).
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        model.filterText = ""; await settle()
                        model.displayedRoot = 0; model.expanded = []; model.refreshOutline(); model.tab = .treemap; await settle()
                        DemoInput.click(fromTop: 96, x: 168)
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        let c2Before = model.selected, c2T0 = Perf.now()
                        DemoInput.click(fromTop: 180, x: 168)   // a different row, so a selection change is expected
                        while model.selected == c2Before && Perf.ms(since: c2T0) < 5000 { try? await Task.sleep(nanoseconds: 1_000_000) }
                        Perf.log("click-latency-later (a second, warm click; post -> selection changed): \(String(format: "%.1f", Perf.ms(since: c2T0))) ms")
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        DemoInput.click(fromTop: 96, x: 168)
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        let k = model.selected
                        DemoInput.key(124, chars: String(UnicodeScalar(NSRightArrowFunctionKey)!)); await settle()
                        Check.expect("right-arrow-expands-selected-folder", k != nil && model.expanded.contains(k!), "node=\(k.map(String.init) ?? "nil")")
                        DemoInput.key(123, chars: String(UnicodeScalar(NSLeftArrowFunctionKey)!)); await settle()
                        Check.expect("left-arrow-collapses-it", k != nil && !model.expanded.contains(k!))
                        DemoInput.key(36, chars: "\r"); await settle()
                        Check.expect("return-drills-into-the-folder", k != nil && model.displayedRoot == k!, "root=\(model.displayedRoot)")
                        mark(13)
                        // Step 13: a real Trash round trip on a disposable synthetic folder, restricted to that folder by construction.
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        let fx = "/tmp/spz-trash-fixture"
                        try? FileManager.default.removeItem(atPath: fx)
                        try? FileManager.default.createDirectory(atPath: fx, withIntermediateDirectories: true)
                        let victimPath = fx + "/victim-\(ProcessInfo.processInfo.processIdentifier).bin", keepPath = fx + "/keep.bin"
                        try? Data(repeating: 7, count: 300_000).write(to: URL(fileURLWithPath: victimPath))
                        try? Data(repeating: 8, count: 200_000).write(to: URL(fileURLWithPath: keepPath))
                        model.trashItem = { url in
                            guard url.path.hasPrefix(fx + "/") || url.path.hasPrefix("/private" + fx + "/") else { throw CocoaError(.fileWriteNoPermission) }
                            return try realTrash(url)
                        }
                        model.filterText = ""; model.displayedRoot = 0; model.expanded = []
                        Perf.log("fixture: scan start")
                        model.scan(fx)
                        var waited = 0
                        while model.scanning && waited < 100 { try? await Task.sleep(nanoseconds: 200_000_000); waited += 1 }
                        Perf.log("fixture: scan done scanning=\(model.scanning) waited=\(waited) nodes=\(model.tree.map { String($0.nodeCount) } ?? "nil") err=\(model.error ?? "nil")")
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if let t = model.tree, let id = (0..<UInt32(t.nodeCount)).first(where: { t.path($0).hasSuffix("/" + (victimPath as NSString).lastPathComponent) }) {
                            model.selected = id
                            model.proposeRemoval(of: id)
                            model.confirmRemoval()
                            let fm = FileManager.default
                            let trashed = model.lastRemoved.first?.trashed
                            Check.expect("real-trash-moves-only-the-selected-fixture", !fm.fileExists(atPath: victimPath) && fm.fileExists(atPath: keepPath) && model.lastRemoved.count == 1 && (trashed.map { fm.fileExists(atPath: $0.path) } ?? false), "message=\(model.removalMessage ?? "nil")")
                            try? await Task.sleep(nanoseconds: 1_000_000_000); mark(14)
                            model.undoRemoval()
                            Check.expect("undo-restores-the-fixture", fm.fileExists(atPath: victimPath) && !(trashed.map { fm.fileExists(atPath: $0.path) } ?? true))
                        } else {
                            Check.expect("real-trash-moves-only-the-selected-fixture", false, "fixture node not found")
                            Check.expect("undo-restores-the-fixture", false, "fixture node not found")
                            mark(14)
                        }
                        try? FileManager.default.removeItem(atPath: fx)
                        mark(15)
                        // Step 15b: rescan soak. Alternate a large and a tiny scan, expand, cancel mid-scan, and track footprint.
                        model.trashItem = { _ in throw CocoaError(.fileWriteNoPermission) }
                        var foot: [Double] = []
                        var alive = true
                        for i in 0..<8 {
                            model.filterText = ""; model.displayedRoot = 0
                            model.scan(i % 2 == 0 ? "/Library" : "/usr/share")
                            var w = 0
                            while model.scanning && w < 300 { try? await Task.sleep(nanoseconds: 200_000_000); w += 1 }
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            if let t = model.tree, let first = model.outlineRows.first?.node { _ = t; model.toggle(first) }
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            let mb = Footprint.megabytes()
                            foot.append(mb)
                            Perf.log("soak cycle=\(i) footprint_mb=\(String(format: "%.0f", mb)) nodes=\(model.tree.map { String($0.nodeCount) } ?? "nil") scanning=\(model.scanning)")
                            alive = alive && !model.scanning
                        }
                        // Plateau check: the last two large-scan cycles must not exceed the first two by more than 25%.
                        let early = max(foot[0], foot[2]), late = max(foot[4], foot[6])
                        Check.expect("rescan-memory-plateaus-over-8-cycles", late <= early * 1.25 && alive, "early_max_mb=\(String(format: "%.0f", early)) late_max_mb=\(String(format: "%.0f", late)) all_mb=\(foot.map { String(format: "%.0f", $0) }.joined(separator: ","))")
                        // Cancel mid-scan of the large folder: must end with scanning=false and a valid (partial) tree, no crash.
                        model.scan("/Library")
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        let sawScanning = model.scanning
                        model.cancel()
                        var cw = 0
                        while model.scanning && cw < 100 { try? await Task.sleep(nanoseconds: 100_000_000); cw += 1 }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        let partial = model.tree.map { $0.wasCancelled && $0.nodeCount > 0 && $0.nodeCount < 153_000 } ?? false
                        Perf.log("cancel: sawScanning=\(sawScanning) scanning=\(model.scanning) nodes=\(model.tree.map { String($0.nodeCount) } ?? "nil") cancelled=\(model.tree.map { String($0.wasCancelled) } ?? "nil")")
                        Check.expect("cancel-mid-scan-leaves-a-usable-partial-tree", sawScanning && !model.scanning && partial, "nodes=\(model.tree.map { String($0.nodeCount) } ?? "nil")")
                        model.scan("/usr/share")
                        while model.scanning { try? await Task.sleep(nanoseconds: 200_000_000) }
                        Check.expect("rescan-after-cancel-works", (model.tree?.nodeCount ?? 0) > 1000 && !(model.tree?.wasCancelled ?? true), "nodes=\(model.tree.map { String($0.nodeCount) } ?? "nil")")
                        // Reveal: select a deep file (as a Largest-list click would) while everything is collapsed.
                        model.filterText = ""; model.displayedRoot = 0; model.expanded = []; model.refreshOutline(); model.tab = .largest
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if let t = model.tree, let deep = model.largestIDs.first {
                            let rowsBefore = model.outlineRows.count
                            model.selected = deep
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            let shown = model.outlineIndex[deep] != nil
                            Check.expect("selecting-a-hidden-file-reveals-its-folders", shown && model.outlineRows.count > rowsBefore, "rows \(rowsBefore)->\(model.outlineRows.count) path=\(t.path(deep))")
                        } else {
                            Check.expect("selecting-a-hidden-file-reveals-its-folders", false, "no largest file")
                        }
                        // Filters beyond name/kind/min size: extension and maximum size, verified against the Rust result.
                        if let t = model.tree, let probe = model.largestIDs.first, let dot = t.name(probe).lastIndex(of: "."), dot != t.name(probe).startIndex {
                            let ext = String(t.name(probe)[t.name(probe).index(after: dot)...]).lowercased()
                            model.clearFilters(); model.filterExt = ext
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            let ids = model.largestIDs
                            let allMatch = !ids.isEmpty && ids.allSatisfy { t.name($0).lowercased().hasSuffix("." + ext) }
                            Check.expect("extension-filter-keeps-only-that-extension", allMatch && model.activeFilter != nil, "ext=\(ext) shown=\(ids.count)")
                            model.clearFilters(); model.filterMaxMB = 1
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            let ids2 = model.largestIDs
                            Check.expect("max-size-filter-keeps-only-small-files", !ids2.isEmpty && ids2.allSatisfy { t.info($0).size <= 1_000_000 }, "shown=\(ids2.count) largest=\(ids2.first.map { String(t.info($0).size) } ?? "nil")")
                            model.clearFilters()
                        } else {
                            Check.expect("extension-filter-keeps-only-that-extension", false, "no probe file with an extension")
                            Check.expect("max-size-filter-keeps-only-small-files", false, "no probe file")
                        }
                        // Modified-date filter through the UI model: a narrower window can never match more than a wider one.
                        model.clearFilters(); model.filterModifiedDays = 3650
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        let wide = model.activeFilter?.totalCount ?? 0
                        model.filterModifiedDays = 1
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        let narrow = model.activeFilter?.totalCount ?? UInt64.max
                        model.clearFilters()
                        Check.expect("date-filter-narrow-window-never-exceeds-wide", wide > 0 && narrow <= wide, "10y=\(wide) 1d=\(narrow)")
                        // Outline sort through the UI model: name order is alphabetical among top-level rows; size-ascending is monotonic.
                        if let t = model.tree {
                            model.outlineSort = .name
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            let top = model.outlineRows.filter { $0.depth == 0 }.map { t.name($0.node).lowercased() }
                            let byName = top.count > 1 && zip(top, top.dropFirst()).allSatisfy { $0 <= $1 }
                            model.outlineSort = .sizeAscending
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            let sz = model.outlineRows.filter { $0.depth == 0 }.map { t.info($0.node).size }
                            let bySize = sz.count > 1 && zip(sz, sz.dropFirst()).allSatisfy { $0 <= $1 }
                            model.outlineSort = .sizeDescending
                            Check.expect("outline-sort-name-and-size-order", byName && bySize, "top=\(top.count) name=\(byName) size=\(bySize)")
                        }
                        mark(16)
                        // Steps 17-19: visual evidence without a modal in the way. Step 15's "Moved ... to the Trash" alert
                        // covered the earlier screenshots, so dismiss it, widen the sidebar so folder item counts show, and open the menus.
                        model.removalMessage = nil; model.pendingRemoval = nil; model.clearFilters(); model.selected = nil
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        let split = DemoInput.allViews(of: NSSplitView.self).first
                        split?.setPosition(460, ofDividerAt: 0)
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        let outline = DemoInput.allViews(of: NSTableView.self).first { $0.tableColumns.first?.identifier.rawValue == "outline" }
                        let sideW = outline?.view(atColumn: 0, row: 0, makeIfNecessary: true)?.bounds.width ?? 0
                        Check.expect("sidebar-widened-for-counts-no-modal", sideW >= 400 && model.removalMessage == nil, "sidebar=\(Int(sideW))")
                        mark(17)
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        let pops = DemoInput.allViews(of: NSPopUpButton.self).filter { $0.convert($0.bounds, to: nil).minX < 700 }
                            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($0.bounds, to: nil).minX }
                        Check.expect("filter-and-sort-menu-buttons-found", pops.count >= 2, "popups=\(pops.count)")
                        // Real control interactions (not model mutation): type in the ext field, pick menu items through NSMenu.
                        if let field = DemoInput.allViews(of: NSTextField.self).first(where: { ($0.placeholderString ?? "") == "ext" }), let w = field.window {
                            w.makeFirstResponder(field)
                            field.currentEditor()?.insertText("pdf")
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            Check.expect("typing-in-ext-field-applies-extension-filter", model.filterExt == "pdf" && model.filterIsActive, "ext=\(model.filterExt)")
                            w.makeFirstResponder(nil)
                        } else { Check.expect("typing-in-ext-field-applies-extension-filter", false, "ext field not found") }
                        // Menu tracking uses a different run-loop mode. Default-mode timers never fired in E1c.
                        // Each interaction gets a fresh open, common-mode driver, and a bounded cancellation.
                        final class Picks: @unchecked Sendable { var done: [String: Bool] = [:]; var titles: [String] = [] }
                        let picks = Picks()
                        @MainActor func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
                            let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { action() } }
                            RunLoop.main.add(timer, forMode: .common)
                            RunLoop.main.add(timer, forMode: .eventTracking)
                        }
                        @MainActor func drive(_ button: NSPopUpButton, title: String, key: String, step: Int?) {
                            schedule(2) {
                                guard let menu = button.menu else { return }
                                func find(_ m: NSMenu) -> (NSMenu, Int)? {
                                    for (i, item) in m.items.enumerated() {
                                        picks.titles.append(item.title)
                                        if item.title == title { return (m, i) }
                                        if let sub = item.submenu { sub.update(); if let result = find(sub) { return result } }
                                    }
                                    return nil
                                }
                                if let (m, i) = find(menu) {
                                    picks.done[key] = true
                                    m.performActionForItem(at: i)
                                }
                                menu.cancelTracking()
                            }
                            schedule(15) { button.menu?.cancelTracking() }
                            if let step { schedule(0.4) { mark(step) } }
                            button.performClick(nil)
                        }
                        @MainActor func captureChoices(_ button: NSPopUpButton, parentTitle: String, step: Int) {
                            schedule(1) {
                                guard let menu = button.menu, let i = menu.items.firstIndex(where: { $0.title == parentTitle }), let sub = menu.items[i].submenu else {
                                    Check.expect("submenu-visible-\(step)", false, "missing parent menu"); mark(step); button.menu?.cancelTracking(); return
                                }
                                // Action dispatch picks effects but does not enter submenu tracking.
                                // Navigate the actual tracked menu with native down/right events instead.
                                func navigationKey(_ code: UInt16, _ scalar: Int) {
                                    let chars = String(UnicodeScalar(scalar)!)
                                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                                        if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: button.window?.windowNumber ?? 0, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                                            NSApp.postEvent(event, atStart: false)
                                        }
                                    }
                                }
                                // Fresh tracking begins with no highlighted item. Count actual selectable items.
                                let steps = max(0, menu.items.prefix(i + 1).filter { !$0.isSeparatorItem && $0.isEnabled && !$0.isHidden }.count - 1)
                                // Home normalizes any inherited highlight to the first selectable item.
                                navigationKey(115, NSHomeFunctionKey)
                                for offset in 0..<steps { schedule(0.15 + Double(offset) * 0.12) { navigationKey(125, NSDownArrowFunctionKey) } }
                                schedule(Double(steps) * 0.12 + 0.3) { navigationKey(124, NSRightArrowFunctionKey) }
                                schedule(Double(steps) * 0.12 + 0.8) {
                                    Check.expect("submenu-parent-tracking-\(step)", menu.highlightedItem === menu.items[i], "parent=\(parentTitle) highlighted=\(menu.highlightedItem?.title ?? "nil") items=\(sub.items.count); pixels required")
                                    mark(step)
                                    menu.cancelTracking()
                                }
                            }
                            schedule(45) { button.menu?.cancelTracking() }
                            button.performClick(nil)
                        }
                        var dateEffect = false, sortEffect = false, resetEffect = false
                        if pops.count >= 2 {
                            drive(pops[0], title: "Last 7 days", key: "date", step: 18)
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            dateEffect = model.filterModifiedDays == 7 && model.filterExt == "pdf" && !model.filterPending
                            Perf.log("date action effect: days=\(model.filterModifiedDays) ext=\(model.filterExt) pending=\(model.filterPending)")
                            captureChoices(pops[0], parentTitle: "Modified", step: 23)
                            captureChoices(pops[0], parentTitle: "Maximum size", step: 24)
                            drive(pops[1], title: "Name", key: "sort", step: 19)
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            sortEffect = model.outlineSort == .name
                            captureChoices(pops[1], parentTitle: "Sort folders by", step: 25)
                            // Seed every independent filter, then reset through the actual menu action.
                            model.filterText = "doc"; model.filterExt = "pdf"; model.filterKind = .document
                            model.filterMinMB = 1; model.filterMaxMB = 100; model.filterModifiedDays = 7
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            drive(pops[0], title: "Clear all filters", key: "clear", step: nil)
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            resetEffect = model.filterText.isEmpty && model.filterExt.isEmpty && model.filterKind == nil
                                && model.filterMinMB == 0 && model.filterMaxMB == 0 && model.filterModifiedDays == 0
                                && !model.filterIsActive && !model.filterPending && model.activeFilter == nil
                                && !model.outlineRows.isEmpty
                        }
                        Perf.log("menu titles seen: \(picks.titles.joined(separator: " | "))")
                        Check.expect("menu-items-change-date-filter-and-sort", picks.done["date"] == true && picks.done["sort"] == true && dateEffect && sortEffect,
                                     "dateEffect=\(dateEffect) sortEffect=\(sortEffect) days=\(model.filterModifiedDays) sort=\(model.outlineSort)")
                        Check.expect("clear-all-filters-menu-item-resets", picks.done["clear"] == true && resetEffect, "resetEffect=\(resetEffect)")
                        mark(20)
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        // Dedicated disposable fixture: empty folders, a five-digit count and a depth-12 folder.
                        let countRoot = URL(fileURLWithPath: "/tmp/spz-count-fixture")
                        try? FileManager.default.removeItem(at: countRoot)
                        do {
                            try await Task.detached {
                                let fm = FileManager.default
                                try fm.createDirectory(at: countRoot, withIntermediateDirectories: true)
                                try fm.createDirectory(at: countRoot.appendingPathComponent("a-empty"), withIntermediateDirectories: true)
                                let large = countRoot.appendingPathComponent("b-large")
                                try fm.createDirectory(at: large, withIntermediateDirectories: true)
                                for i in 0..<10001 { fm.createFile(atPath: large.appendingPathComponent("item-\(i)").path, contents: Data()) }
                                let deep = countRoot.appendingPathComponent((1...12).map { "z-deep-\($0)" }.joined(separator: "/"))
                                try fm.createDirectory(at: deep, withIntermediateDirectories: true)
                                try fm.createDirectory(at: deep.appendingPathComponent("empty-deep"), withIntermediateDirectories: true)
                            }.value
                            model.scan(countRoot.path)
                            while model.scanning { try? await Task.sleep(nanoseconds: 100_000_000) }
                            if let t = model.tree {
                                let largeID = (0..<UInt32(t.nodeCount)).first { t.name($0) == "b-large" && t.info($0).parent == 0 }
                                model.selected = nil
                                model.expanded = Set((0..<UInt32(t.nodeCount)).filter { t.info($0).childCount > 0 && $0 != largeID })
                                Perf.log("fixture largeID=\(String(describing: largeID)) excluded=\(largeID.map { !model.expanded.contains($0) } ?? false)")
                                Check.expect("fixture-large-identity-excluded", largeID != nil && largeID.map { !model.expanded.contains($0) } == true)
                                model.refreshOutline()
                                Perf.log("count fixture expanded=\(model.expanded.count) rootRows=\(t.info(0).childCount)")
                            }
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            Check.expect("fixture-projection-depth12-not-large-descendants", model.outlineRows.contains { $0.depth >= 12 } && !model.outlineRows.contains { model.tree?.name($0.node).hasPrefix("item-") == true })
                            // Keep a top empty folder, large count and deep folders in the same visual frame.
                            model.outlineSort = .name
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            var dividerPosition: CGFloat = 410
                            if let split {
                                split.setPosition(dividerPosition, ofDividerAt: 0)
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                dividerPosition += 399 - OutlineDemoEvidence.width
                                split.setPosition(dividerPosition, ofDividerAt: 0)
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                            }
                            Check.expect("counts-hidden-below-400", OutlineDemoEvidence.width > 397 && OutlineDemoEvidence.width < 400 && OutlineDemoEvidence.countsVisible(false) && OutlineDemoEvidence.hasVisibleDeepRow, "cellWidth=\(OutlineDemoEvidence.width)")
                            mark(21)
                            try? await Task.sleep(nanoseconds: 4_000_000_000)
                            if let split {
                                dividerPosition += 401 - OutlineDemoEvidence.width
                                split.setPosition(dividerPosition, ofDividerAt: 0)
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                            }
                            let largeText = "\(10001.formatted()) items"
                            Check.expect("counts-visible-above-400-empty-large-deep", OutlineDemoEvidence.width >= 400 && OutlineDemoEvidence.width < 403 && OutlineDemoEvidence.countsVisible(true)
                                         && OutlineDemoEvidence.hasCount("0 items") && OutlineDemoEvidence.hasCount(largeText) && OutlineDemoEvidence.hasVisibleDeepCount, "cellWidth=\(OutlineDemoEvidence.width) large=\(largeText)")
                            mark(22)
                            try? await Task.sleep(nanoseconds: 4_000_000_000)
                            // E2 mode matrix changes only the CI view environment, never system preferences.
                            let savedAppearance = NSApp.appearance
                            NSApp.appearance = NSAppearance(named: .aqua)
                            DemoInput.window?.setContentSize(NSSize(width: 960, height: 600))
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            Check.expect("e2-minimum-window-fits", abs(DemoRootLayout.size.width - 960) < 1 && abs(DemoRootLayout.size.height - 600) < 1 && DemoInput.window?.contentLayoutRect.width == 960 && DemoInput.window?.contentLayoutRect.height == 600, "root=\(DemoRootLayout.size) layout=\(String(describing: DemoInput.window?.contentLayoutRect.size)) contentView=\(String(describing: DemoInput.window?.contentView?.bounds.size)); all required, pixels decide")
                            mark(26)
                            NSApp.appearance = NSAppearance(named: .darkAqua)
                            try? await Task.sleep(nanoseconds: 1_000_000_000); mark(27)
                            demoReduceTransparency = true; demoReduceMotion = true
                            try? await Task.sleep(nanoseconds: 1_000_000_000); mark(28)
                            NSApp.appearance = NSAppearance(named: .aqua)
                            try? await Task.sleep(nanoseconds: 1_000_000_000); mark(29)
                            Check.expect("e2-live-mode-toggle", demoReduceTransparency && demoReduceMotion)
                            Check.expect("e2-outline-accessible-labels", OutlineDemoEvidence.accessibleFolderLabels)
                            if let table = OutlineDemoEvidence.table, let w = table.window {
                                w.makeFirstResponder(table)
                                let before = model.selected
                                DemoInput.key(125)
                                try? await Task.sleep(nanoseconds: 700_000_000)
                                Check.expect("e2-keyboard-in-reduced-mode", model.selected != nil && model.selected != before)
                            } else { Check.expect("e2-keyboard-in-reduced-mode", false, "outline missing") }
                            demoReduceTransparency = false; demoReduceMotion = false; NSApp.appearance = savedAppearance
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            Check.expect("e2-mode-restored", !demoReduceTransparency && !demoReduceMotion)
                            mark(30)
                            // E2 count readability: selected/unselected, both appearances and contrast branches.
                            for (step, appearance, increase) in [(31, NSAppearance.Name.aqua, false), (32, .darkAqua, false), (33, .aqua, true), (34, .darkAqua, true)] {
                                NSApp.appearance = NSAppearance(named: appearance)
                                model.demoIncreaseContrast = increase
                                if let table = OutlineDemoEvidence.table, let window = table.window {
                                    window.makeFirstResponder(table)
                                }
                                try? await Task.sleep(nanoseconds: 700_000_000)
                                Check.expect("e2-count-color-contract-\(step)", OutlineDemoEvidence.countColorContract(increased: increase))
                                mark(step)
                            }
                            // Inactive selection must not leave stale emphasized white text on neutral background.
                            let selectedBeforeInactive = model.selected
                            let tableRowBeforeInactive = OutlineDemoEvidence.table?.selectedRow
                            DemoInput.window?.resignKey()
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            Check.expect("e2-inactive-count-color-policy", OutlineDemoEvidence.inactiveSelectedCountPolicy && selectedBeforeInactive != nil && model.selected == selectedBeforeInactive && OutlineDemoEvidence.table?.selectedRow == tableRowBeforeInactive && selectedBeforeInactive.flatMap { model.outlineIndex[$0] } == tableRowBeforeInactive)
                            mark(35)
                            DemoInput.window?.makeKeyAndOrderFront(nil)
                            if let table = OutlineDemoEvidence.table {
                                table.reloadData()
                                if let node = model.selected, let row = model.outlineIndex[node] { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                            }
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            Check.expect("e2-count-visible-reload-color-policy", OutlineDemoEvidence.countColorContract(increased: true) && model.selected == selectedBeforeInactive && OutlineDemoEvidence.table?.selectedRow == tableRowBeforeInactive && selectedBeforeInactive.flatMap { model.outlineIndex[$0] } == tableRowBeforeInactive, "style=\(OutlineDemoEvidence.selectionDiagnostic) key=\(DemoInput.window?.isKeyWindow ?? false) responder=\(String(describing: DemoInput.window?.firstResponder)) node=\(String(describing: model.selected)) row=\(OutlineDemoEvidence.table?.selectedRow ?? -1) expectedRow=\(tableRowBeforeInactive ?? -1)")
                            mark(36)
                            model.demoIncreaseContrast = nil; NSApp.appearance = savedAppearance
                            if let table = OutlineDemoEvidence.table, let window = table.window {
                                let selectedBefore = model.selected
                                window.makeFirstResponder(table)
                                let intendedControl = table.nextValidKeyView
                                DemoInput.key(48, chars: "\t")
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                let responder = window.firstResponder
                                let focusMoved = intendedControl != nil && intendedControl !== table && !intendedControl!.isHidden && intendedControl!.window === window && ((intendedControl as? NSControl)?.isEnabled ?? true)
                                    && (responder === intendedControl || (responder as? NSTextView)?.delegate === intendedControl)
                                Check.expect("e2-tab-leaves-outline-without-selection-change", focusMoved && model.selected == selectedBefore, "key=\(window.isKeyWindow) intended=\(String(describing: intendedControl)) responder=\(String(describing: responder)) delegate=\(String(describing: (responder as? NSTextView)?.delegate)) selectedBefore=\(String(describing: selectedBefore)) selectedAfter=\(String(describing: model.selected))")
                                // Escape must not invoke a destructive action or clear the current tree.
                                let treeBefore = model.tree, removedBefore = model.lastRemoved.count
                                let pendingBefore = model.pendingRemoval, messageBefore = model.removalMessage
                                DemoInput.key(53, chars: String(UnicodeScalar(27)!))
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                Check.expect("e2-escape-preserves-tree-and-removal-state", model.tree === treeBefore && model.lastRemoved.count == removedBefore && pendingBefore == nil && messageBefore == nil && model.pendingRemoval == pendingBefore && model.removalMessage == messageBefore)
                                window.makeFirstResponder(table)
                                Check.expect("e2-outline-single-selection-policy", !table.allowsMultipleSelection && table.selectedRowIndexes.count <= 1)
                            } else {
                                Check.expect("e2-tab-leaves-outline-without-selection-change", false, "table missing")
                                Check.expect("e2-escape-preserves-tree-and-removal-state", false, "table missing")
                                Check.expect("e2-outline-single-selection-policy", false, "table missing")
                            }
                            try? Data().write(to: URL(fileURLWithPath: "/tmp/spz-demo-finished"))

                        } catch {
                            Check.expect("counts-hidden-below-400", false, "fixture error: \(error)")
                            Check.expect("counts-visible-above-400-empty-large-deep", false, "fixture error: \(error)")
                            mark(21); try? await Task.sleep(nanoseconds: 4_000_000_000); mark(22)
                        }
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

/// CI-only: posts NSEvents straight to the app's key window so the real responder chain and SwiftUI focus handle them.
@MainActor enum DemoInput {
    static func allViews<T: NSView>(of type: T.Type) -> [T] {
        var out: [T] = []
        func walk(_ v: NSView) { if let t = v as? T { out.append(t) }; v.subviews.forEach(walk) }
        for w in NSApp.windows where w.isVisible { if let c = w.contentView?.superview ?? w.contentView { walk(c) } }
        return out
    }
    static var window: NSWindow? { NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } }
    static func click(fromTop y: CGFloat, x: CGFloat) {
        guard let w = window else { Perf.log("kbd: no window"); return }
        let p = NSPoint(x: x, y: w.frame.height - y)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
        }
    }
    static func move(fromTop y: CGFloat, x: CGFloat) {
        guard let w = window else { return }
        let p = NSPoint(x: x, y: w.frame.height - y)
        if let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { NSApp.postEvent(e, atStart: false) }
    }
    static func key(_ code: UInt16, chars: String? = nil) {
        guard let w = window else { return }
        let ch = chars ?? (code == 125 ? String(UnicodeScalar(NSDownArrowFunctionKey)!) : "")
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                        isARepeat: false, keyCode: code) { NSApp.postEvent(e, atStart: false) }
        }
    }
}

/// CI-only: pass/fail assertions, written to their own file so evidence never depends on log truncation.
@MainActor enum Check {
    static func expect(_ name: String, _ ok: Bool, _ detail: String = "") {
        let line = "\(ok ? "PASS" : "FAIL") \(name) \(detail)\n"
        let url = URL(fileURLWithPath: "/tmp/spz-assertions.txt")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() } else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        Perf.log("check \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}


/// Physical memory footprint of this process (what Activity Monitor calls Memory), in MB.
enum Footprint {
    static func megabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}

/// Injects test preferences only for the scripted demo. Normal app inherits live system environments.
private struct DemoAccessibilityModes: ViewModifier {
    let reduceTransparency: Bool
    let reduceMotion: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if Perf.on {
            content.environment(\.demoReduceTransparency, reduceTransparency)
                .environment(\.demoReduceMotion, reduceMotion)
        } else { content }
    }
}

/// Holds exactly one computed publication until the newer operation has completed.
/// Token-specific completion proves the old main-actor closure ran, rather than relying on sleeps.
private actor PublicationBarrier {
    let stage: String
    private var token: UUID?
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    init(_ stage: String) { self.stage = stage }
    func before(_ stage: String, _ generation: UInt64, _ publication: UUID) async {
        guard stage == self.stage, token == nil else { return }
        token = publication
        await withCheckedContinuation { continuation = $0 }
    }
    func after(_ stage: String, _ generation: UInt64, _ publication: UUID) {
        if stage == self.stage && publication == token { finished = true }
    }
    func release() { continuation?.resume(); continuation = nil }
    func parked() -> Bool { continuation != nil }
    func completed() -> Bool { finished }
}

@MainActor private enum PublicationRegression {
    static func wait(_ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
    static func run(tree: Tree) async {
        let m = AppModel(); m.tree = tree
        let filter = PublicationBarrier("filter")
        m.beforePublish = { await filter.before($0, $1, $2) }
        m.afterPublish = { await filter.after($0, $1, $2) }
        m.filterText = "not-present-old-filter"
        let parked = await wait { await filter.parked() }
        m.clearFilters()
        let newer = await wait { !m.filterPending && m.activeFilter == nil }
        let revision = m.filterRevision
        let filterStillHeld = !(await filter.completed())
        await filter.release()
        let completed = await wait { await filter.completed() }
        Check.expect("race-old-filter-after-newer-rejected", parked && newer && completed && filterStillHeld && m.activeFilter == nil && !m.filterPending && m.filterRevision == revision)

        let outline = PublicationBarrier("outline")
        m.beforePublish = { await outline.before($0, $1, $2) }
        m.afterPublish = { await outline.after($0, $1, $2) }
        m.refreshOutline()
        let outlineParked = await wait { await outline.parked() }
        m.tree = nil; m.selected = nil; m.refreshOutline()
        let outlineRevision = m.outlineRevision
        let outlineStillHeld = !(await outline.completed())
        await outline.release()
        let outlineCompleted = await wait { await outline.completed() }
        Check.expect("race-old-outline-after-tree-clear-rejected", outlineParked && outlineCompleted && outlineStillHeld && m.outlineRows.isEmpty && m.outlineIndex.isEmpty && m.selected == nil && m.outlineRevision == outlineRevision)

        // A different arena may reuse numeric NodeIds. Reject old rows even if ids look valid.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spz-publication-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("new-tree-only").path, contents: Data())
        let replacement = await ScanSession(root: root.path, excludes: [])?.run { _ in }
        m.tree = tree
        let swapped = PublicationBarrier("outline")
        m.beforePublish = { await swapped.before($0, $1, $2) }
        m.afterPublish = { await swapped.after($0, $1, $2) }
        m.refreshOutline()
        let swapParked = await wait { await swapped.parked() }
        m.tree = replacement; m.expanded = []; m.selected = nil; m.refreshOutline()
        let swapNewer = await wait { m.outlineRows.count == 1 && replacement?.name(m.outlineRows[0].node) == "new-tree-only" }
        let swapRows = m.outlineRows.map { $0.node }, swapRevision = m.outlineRevision
        let swapStillHeld = !(await swapped.completed())
        await swapped.release()
        let swapCompleted = await wait { await swapped.completed() }
        Check.expect("race-old-outline-after-tree-swap-rejected", swapParked && swapNewer && swapCompleted && swapStillHeld && (m.outlineRows.map { $0.node }) == swapRows && m.outlineRevision == swapRevision && m.selected == nil)
        // Hold scan messages from a real old session while a newer session completes.
        for stage in ["scan-progress", "scan-completion"] {
            let scanModel = AppModel(), scanBarrier = PublicationBarrier(stage)
            scanModel.beforePublish = { await scanBarrier.before($0, $1, $2) }
            scanModel.afterPublish = { await scanBarrier.after($0, $1, $2) }
            scanModel.scan(tree.path(0))
            let scanParked = await wait { await scanBarrier.parked() }
            scanModel.scan(root.path)
            let scanNewer = await wait { !scanModel.scanning && replacement != nil && scanModel.tree != nil && scanModel.tree?.path(0) == replacement?.path(0) && scanModel.tree !== tree }
            let currentTree = scanModel.tree, currentRevision = scanModel.revision
            let currentItems = scanModel.progress.items, currentBytes = scanModel.progress.bytes
            let currentElapsed = scanModel.elapsed, currentSeconds = scanModel.lastScanSeconds
            let scanStillHeld = !(await scanBarrier.completed())
            await scanBarrier.release()
            let scanCompleted = await wait { await scanBarrier.completed() }
            Check.expect("race-old-\(stage)-after-new-scan-rejected", scanParked && scanNewer && scanCompleted && scanStillHeld && scanModel.tree === currentTree && scanModel.revision == currentRevision && scanModel.progress.items == currentItems && scanModel.progress.bytes == currentBytes && scanModel.elapsed == currentElapsed && scanModel.lastScanSeconds == currentSeconds && !scanModel.scanning && scanModel.error == nil)
            scanModel.beforePublish = nil; scanModel.afterPublish = nil
        }
        try? FileManager.default.removeItem(at: root)

        m.tree = tree
        let derived = PublicationBarrier("derived")
        m.beforePublish = { await derived.before($0, $1, $2) }
        m.afterPublish = { await derived.after($0, $1, $2) }
        m.refreshDerived()
        let derivedParked = await wait { await derived.parked() }
        m.tree = nil; m.refreshDerived()
        let derivedStillHeld = !(await derived.completed())
        await derived.release()
        let derivedCompleted = await wait { await derived.completed() }
        Check.expect("race-old-derived-after-clear-rejected", derivedParked && derivedCompleted && derivedStillHeld && m.largestIDs.isEmpty && m.kindRows.isEmpty)
        m.beforePublish = nil; m.afterPublish = nil
    }
}

@MainActor private enum ZeroMatchRegression {
    static func run() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spz-zero-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("empty.pdf").path, contents: Data())
        FileManager.default.createFile(atPath: root.appendingPathComponent("other.txt").path, contents: Data())
        defer { try? FileManager.default.removeItem(at: root) }
        let m = AppModel(); m.scan(root.path)
        let deadline = Date().addingTimeInterval(10)
        while m.scanning && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        guard let tree = m.tree, let zero = (0..<UInt32(tree.nodeCount)).first(where: { tree.name($0) == "empty.pdf" }),
              let hidden = (0..<UInt32(tree.nodeCount)).first(where: { tree.name($0) == "other.txt" }) else {
            Check.expect("zero-match-selection-removal-policy", false, "fixture missing")
            return
        }
        m.filterExt = "pdf"
        while m.filterPending && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        var calls = 0
        m.trashItem = { url in calls += 1; return url }
        let visible = m.activeFilter?.count(zero) == 1 && m.activeFilter?.size(zero) == 0 && !m.isOutsideFilter(zero) && m.removalBlockedReason(zero) == nil
        m.proposeRemoval(of: hidden)
        let hiddenBlocked = m.pendingRemoval == nil && calls == 0
        m.removalMessage = nil
        m.proposeRemoval(of: zero)
        let opened = m.pendingRemoval == zero && calls == 0
        m.confirmRemoval()
        Check.expect("zero-match-selection-removal-policy", visible && hiddenBlocked && opened && calls == 1, "visible=\(visible) hiddenBlocked=\(hiddenBlocked) opened=\(opened) mockedCalls=\(calls)")
    }
}
