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
                        MainStall.shared.start()
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
                        let sideW = split?.subviews.first?.frame.width ?? 0
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
                        func pick(_ title: String, in b: NSPopUpButton) -> Bool {
                            func find(_ m: NSMenu) -> (NSMenu, Int)? {
                                for (i, it) in m.items.enumerated() {
                                    if it.title == title { return (m, i) }
                                    if let sub = it.submenu, let r = find(sub) { return r }
                                }
                                return nil
                            }
                            guard let m = b.menu, let (mm, i) = find(m) else { return false }
                            mm.performActionForItem(at: i); return true
                        }
                        if pops.count >= 2 {
                            let okDate = pick("Last 7 days", in: pops[0])
                            let okSort = pick("Name", in: pops[1])
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            Check.expect("menu-items-change-date-filter-and-sort", okDate && okSort && model.filterModifiedDays == 7 && model.outlineSort == .name, "date=\(okDate) sort=\(okSort) days=\(model.filterModifiedDays) sortMode=\(model.outlineSort)")
                            let okClear = pick("Clear all filters", in: pops[0])
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            Check.expect("clear-all-filters-menu-item-resets", okClear && !model.filterIsActive, "clear=\(okClear) active=\(model.filterIsActive)")
                            model.filterExt = "pdf"; model.filterModifiedDays = 30; model.outlineSort = .items   // leave filters applied for the menu screenshots
                        }
                        for (k, step) in [(0, 18), (1, 19)] where pops.count > k {
                            let b = pops[k]
                            Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { _ in MainActor.assumeIsolated { b.menu?.cancelTracking() } }
                            Task { @MainActor in try? await Task.sleep(nanoseconds: 300_000_000); mark(step) }
                            b.performClick(nil)   // blocks in menu tracking until the timer cancels it
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                        }
                        mark(20)
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
