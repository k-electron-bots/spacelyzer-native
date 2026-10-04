import CSpacelyzer
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
                    #if SPZ_CI_TESTS   // scripted demo + regression suites exist only in test builds
                    // CI-only scripted interaction so screenshots can show expand, filter and kind views.
                    if env["SPZ_AUTOSCAN"] != nil, env["SPZ_DEMO"] != nil {
                        while model.scanning || model.tree == nil { try? await Task.sleep(nanoseconds: 500_000_000) }
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if env["SPZ_CHECKS"] == "ordering" { await OrderingDriver.run(tree: model.tree!) }   // never returns
                        await PublicationRegression.run(tree: model.tree!)
                        await CommitOrderingRegression.run()
                        await ZeroMatchRegression.run()
                        await AsyncRemovalRegression.run()
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
                        // Workflow starts one bounded chronology capture before acknowledging this cold input.
                        try? "\(ProcessInfo.processInfo.processIdentifier)".write(toFile: "/tmp/spz-cold-click-ready", atomically: true, encoding: .utf8)
                        let sampleDeadline = Date().addingTimeInterval(60)
                        while !FileManager.default.fileExists(atPath: "/tmp/spz-cold-click-ack") && Date() < sampleDeadline { try? await Task.sleep(nanoseconds: 20_000_000) }
                        Perf.log("interaction-sample acknowledged=\(FileManager.default.fileExists(atPath: "/tmp/spz-cold-click-ack"))")
                        // Diagnostic sampled arm: explicit idle settling after profiler readiness or inconclusive ack, not prewarmed input.
                        // This changes idle/arm conditions and cannot be compared as original cold latency.
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        Perf.log("interaction-sample arm=chronology-requested-settle-1s altered-idle=true no-cold-comparability; trace metadata and phase bridges must establish coverage")
                        MainStall.shared.reset() // Exclude ready/ack/startup settling from measured input stalls.
                        InteractionTrace.begin()
                        let clickBefore = model.selected, clickT0 = Perf.now()
                        DemoInput.click(fromTop: 124, x: 168)                       // a visible outline row
                        while model.selected == clickBefore && Perf.ms(since: clickT0) < 5000 { try? await Task.sleep(nanoseconds: 1_000_000) }
                        let clickLatency = Perf.ms(since: clickT0)
                        InteractionTrace.driverResumed(clickLatency, selectionChanged: model.selected != clickBefore)
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        InteractionTrace.finish()
                        Perf.log("click-latency (post -> selection changed): \(String(format: "%.1f", clickLatency)) ms")
                        Perf.log(MainStall.shared.summary("click-only"))
                        MainStall.shared.reset()
                        Perf.log("kbd: after click selected=\(model.selected.map(String.init) ?? "nil")")
                        let idx0 = model.selected.flatMap { n in model.outlineRows.firstIndex { $0.node == n } }
                        Check.expect("click-selects-a-row", idx0 != nil)
                        // Per-key latency: post the key, wait (1 ms polls) until the selection actually changes.
                        InteractionTrace.begin("arrows")
                        var lat: [Double] = []
                        for _ in 0..<40 {
                            let before = model.selected, t0 = Perf.now()
                            DemoInput.key(125)
                            while model.selected == before && Perf.ms(since: t0) < 3000 { try? await Task.sleep(nanoseconds: 1_000_000) }
                            lat.append(Perf.ms(since: t0))
                            InteractionTrace.driverResumed(lat.last!, selectionChanged: model.selected != before)
                            try? await Task.sleep(nanoseconds: 30_000_000)
                        }
                        InteractionTrace.finish()
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
                        let calls = CallCounter()
                        model.trashItem = { url in calls.bump(); return url }
                        func settle() async { try? await Task.sleep(nanoseconds: 1_500_000_000) }
                        let victim: UInt32 = 67
                        model.selected = victim; model.removalMessage = nil; model.pendingRemoval = nil
                        await settle()   // filter 'zzzqqq' is active: victim is outside it
                        model.proposeRemoval(of: victim)
                        Perf.log("guardA propose-outside-filter pending=\(model.pendingRemoval != nil) message=\(model.removalMessage != nil) trashCalls=\(calls.value) expect pending=false message=true calls=0")
                        Check.expect("propose-outside-filter-is-refused", model.pendingRemoval == nil && model.removalMessage != nil && calls.value == 0)
                        model.removalMessage = nil
                        model.filterText = ""; await settle()
                        model.proposeRemoval(of: victim)
                        Perf.log("guardB1 propose-no-filter pending=\(model.pendingRemoval != nil) trashCalls=\(calls.value) expect pending=true calls=0")
                        Check.expect("propose-with-no-filter-opens-confirmation", model.pendingRemoval != nil && calls.value == 0)
                        model.filterText = "zzzqqq"; await settle()   // filter changes while the confirmation is open
                        model.confirmRemoval(); await model.settleRemoval()
                        Perf.log("guardB2 confirm-after-filter-hid-it pending=\(model.pendingRemoval != nil) message=\(model.removalMessage != nil) trashCalls=\(calls.value) expect pending=false message=true calls=0")
                        Check.expect("confirm-after-filter-hid-it-trashes-nothing", model.pendingRemoval == nil && model.removalMessage != nil && calls.value == 0)
                        model.removalMessage = nil
                        model.filterText = ""; await settle()
                        model.proposeRemoval(of: victim); model.confirmRemoval(); await model.settleRemoval()
                        Perf.log("guardC control-no-filter-mocked trashCalls=\(calls.value) expect calls=1 proves-mock-wired")
                        Check.expect("control-unfiltered-confirm-reaches-mock-once", calls.value == 1, "calls=\(calls.value)")
                        model.removalMessage = nil
                        // Typing-race checks: act in the same turn as the filter input changes, before its result lands.
                        let calls0 = calls.value
                        let victim2: UInt32 = 29554
                        model.filterText = ""; await settle(); model.removalMessage = nil
                        model.filterText = "zzzqqq"
                        model.proposeRemoval(of: victim2)
                        Check.expect("propose-right-after-typing-is-refused", model.filterPending && model.pendingRemoval == nil && calls.value == calls0, "pending=\(model.filterPending)")
                        await settle(); model.filterText = ""; await settle(); model.removalMessage = nil
                        model.proposeRemoval(of: victim2)
                        let opened = model.pendingRemoval != nil
                        model.filterText = "lib"
                        model.confirmRemoval(); await model.settleRemoval()
                        Check.expect("confirm-right-after-typing-trashes-nothing", opened && model.filterPending && calls.value == calls0, "opened=\(opened)")
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
                            model.confirmRemoval(); await model.settleRemoval()
                            let fm = FileManager.default
                            let trashed = model.lastRemoved.first?.trashed
                            Check.expect("real-trash-moves-only-the-selected-fixture", !fm.fileExists(atPath: victimPath) && fm.fileExists(atPath: keepPath) && model.lastRemoved.count == 1 && (trashed.map { fm.fileExists(atPath: $0.path) } ?? false), "message=\(model.removalMessage ?? "nil")")
                            try? await Task.sleep(nanoseconds: 1_000_000_000); mark(14)
                            model.undoRemoval(); await model.settleRemoval()
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
                            let focusWindow = OutlineDemoEvidence.table?.window
                            @MainActor func focusDiagnostic(_ phase: String) -> String {
                                let chosen = DemoInput.window
                                return "\(phase) appActive=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) intendedNumber=\(focusWindow?.windowNumber ?? -1) chosenNumber=\(chosen?.windowNumber ?? -1) keyNumber=\(NSApp.keyWindow?.windowNumber ?? -1) mainNumber=\(NSApp.mainWindow?.windowNumber ?? -1) intendedKey=\(focusWindow?.isKeyWindow ?? false) main=\(focusWindow?.isMainWindow ?? false) visible=\(focusWindow?.isVisible ?? false) canBecomeKey=\(focusWindow?.canBecomeKey ?? false) sameChosen=\(focusWindow != nil && chosen === focusWindow) responder=\(String(describing: focusWindow?.firstResponder))"
                            }
                            Perf.log(focusDiagnostic("before-resign"))
                            let inactiveFixture = NSWindow(contentRect: NSRect(x: -1000, y: -1000, width: 80, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
                            inactiveFixture.isReleasedWhenClosed = false
                            inactiveFixture.makeKeyAndOrderFront(nil)
                            Perf.log(focusDiagnostic("after-fixture-key-window"))
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            Check.expect("e2-inactive-count-color-policy", (focusWindow?.isKeyWindow == false) && NSApp.keyWindow === inactiveFixture && OutlineDemoEvidence.inactiveSelectedCountPolicy && selectedBeforeInactive != nil && model.selected == selectedBeforeInactive && OutlineDemoEvidence.table?.selectedRow == tableRowBeforeInactive && selectedBeforeInactive.flatMap { model.outlineIndex[$0] } == tableRowBeforeInactive)
                            mark(35)
                            Perf.log(focusDiagnostic("before-activation"))
                            inactiveFixture.close()
                            NSApp.activate()
                            focusWindow?.makeKeyAndOrderFront(nil)
                            let activationStarted = Date()
                            let activationDeadline = activationStarted.addingTimeInterval(5)
                            while (!NSApp.isActive || !(focusWindow?.isKeyWindow ?? false)) && Date() < activationDeadline { try? await Task.sleep(nanoseconds: 20_000_000) }
                            Perf.log("activation-wait-seconds=\(Date().timeIntervalSince(activationStarted)) \(focusDiagnostic("after-activation-wait"))")
                            let activeSetup = focusWindow != nil && focusWindow === OutlineDemoEvidence.table?.window && NSApp.isActive && (focusWindow?.isKeyWindow ?? false)
                            var responderSetup = false
                            if let table = OutlineDemoEvidence.table {
                                responderSetup = table.window?.makeFirstResponder(table) == true
                                table.reloadData()
                                if let node = model.selected, let row = model.outlineIndex[node] { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                            }
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            Check.expect("e2-count-visible-reload-color-policy", activeSetup && responderSetup && NSApp.isActive && (focusWindow?.isKeyWindow ?? false) && focusWindow?.firstResponder === OutlineDemoEvidence.table && OutlineDemoEvidence.countColorContract(increased: true) && model.selected == selectedBeforeInactive && OutlineDemoEvidence.table?.selectedRow == tableRowBeforeInactive && selectedBeforeInactive.flatMap { model.outlineIndex[$0] } == tableRowBeforeInactive, "style=\(OutlineDemoEvidence.selectionDiagnostic) key=\(DemoInput.window?.isKeyWindow ?? false) responder=\(String(describing: DemoInput.window?.firstResponder)) node=\(String(describing: model.selected)) row=\(OutlineDemoEvidence.table?.selectedRow ?? -1) expectedRow=\(tableRowBeforeInactive ?? -1)")
                            Perf.log(focusDiagnostic("reload-after-responder-wait"))
                            mark(36)
                            model.demoIncreaseContrast = nil; NSApp.appearance = savedAppearance
                            if let table = OutlineDemoEvidence.table, let window = table.window {
                                let selectedBefore = model.selected
                                let tableSetup = window.makeFirstResponder(table)
                                let intendedControl = model.nameFilterKeyView
                                DemoInput.key(48, chars: "\t")
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                let responder = window.firstResponder
                                let focusMoved = activeSetup && tableSetup && NSApp.isActive && window.isKeyWindow && intendedControl != nil && intendedControl !== table && !intendedControl!.isHidden && intendedControl!.window === window && ((intendedControl as? NSControl)?.isEnabled ?? true)
                                    && (responder === intendedControl || (responder as? NSTextView)?.delegate === intendedControl)
                                Check.expect("e2-tab-leaves-outline-without-selection-change", focusMoved && model.selected == selectedBefore, "key=\(window.isKeyWindow) intended=\(String(describing: intendedControl)) responder=\(String(describing: responder)) delegate=\(String(describing: (responder as? NSTextView)?.delegate)) selectedBefore=\(String(describing: selectedBefore)) selectedAfter=\(String(describing: model.selected))")
                                Perf.log("tab-chain tableNext=\(String(describing: table.nextKeyView)) tableNextValid=\(String(describing: table.nextValidKeyView)) fieldPrevious=\(String(describing: intendedControl?.previousKeyView)) fieldPreviousValid=\(String(describing: intendedControl?.previousValidKeyView)) fieldNext=\(String(describing: intendedControl?.nextKeyView)) tableSetup=\(tableSetup) \(focusDiagnostic("post-tab"))")
                                DemoInput.key(48, chars: "\t", modifiers: .shift)
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                let directReverse = focusMoved && window.firstResponder === table && model.selected == selectedBefore
                                Check.expect("e2-explicit-backtab-named-boundary", directReverse, "actual event, not native graph repair")
                                DemoInput.key(48, chars: "\t")
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                let secondFieldStart = directReverse && (window.firstResponder === intendedControl || (window.firstResponder as? NSTextView)?.delegate === intendedControl)
                                // The name field is followed by the extension input in the product filter bar.
                                // Native key-view graph pointers are diagnostic only across SwiftUI hosts.
                                let extensionFields = DemoInput.allViews(of: NSTextField.self).filter { $0.window === window && $0.placeholderString == "ext" && !$0.isHiddenOrHasHiddenAncestor && $0.isEnabled }
                                let fieldForward = extensionFields.count == 1 ? extensionFields.first : nil
                                let nativeForward = intendedControl?.nextValidKeyView
                                let fieldForwardEligible = fieldForward != nil && fieldForward !== table && fieldForward !== intendedControl && fieldForward?.window === window
                                DemoInput.key(48, chars: "\t")
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                let fieldForwardResponder = window.firstResponder
                                let fieldForwardMoved = secondFieldStart && fieldForwardEligible && (fieldForwardResponder === fieldForward || (fieldForwardResponder as? NSTextView)?.delegate === fieldForward)
                                Perf.log("rest-chain-field-forward eligible=\(fieldForwardEligible) actual=\(fieldForwardMoved) extensionCandidates=\(extensionFields.count) intended=\(String(describing: fieldForward)) nativeNext=\(String(describing: nativeForward)) actualDelegate=\(String(describing: (fieldForwardResponder as? NSTextView)?.delegate)) responder=\(String(describing: fieldForwardResponder))")
                                // Return naturally from the downstream view before exercising field backtab.
                                DemoInput.key(48, chars: "\t", modifiers: .shift)
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                let returnedToField = window.firstResponder === intendedControl || (window.firstResponder as? NSTextView)?.delegate === intendedControl
                                let reverseChain = intendedControl?.previousValidKeyView === table
                                DemoInput.key(48, chars: "\t", modifiers: .shift)
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                let returnedToTable = window.firstResponder === table
                                let tableBackward = table.previousValidKeyView
                                let tableBackwardEligible = tableBackward != nil && tableBackward !== table && tableBackward !== intendedControl && tableBackward?.window === window
                                DemoInput.key(48, chars: "\t", modifiers: .shift)
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                let tableBackwardResponder = window.firstResponder
                                let tableBackwardMoved = tableBackwardEligible && (tableBackwardResponder === tableBackward || (tableBackwardResponder as? NSTextView)?.delegate === tableBackward)
                                Perf.log("rest-chain-table-backward eligible=\(tableBackwardEligible) actual=\(tableBackwardMoved) intended=\(String(describing: tableBackward)) responder=\(String(describing: tableBackwardResponder))")
                                Check.expect("e2-shift-tab-returns-to-outline", focusMoved && fieldForwardMoved && returnedToField && returnedToTable && tableBackwardMoved && activeSetup && NSApp.isActive && window.isKeyWindow && model.selected == selectedBefore, "fieldForward=\(fieldForwardMoved) returnedField=\(returnedToField) returnedTable=\(returnedToTable) tableBackward=\(tableBackwardMoved)")
                                await BoundaryGuardRegression.run(restoring: window)
                                // Restore the outline explicitly after testing its upstream route.
                                let escapeSetup = window.makeFirstResponder(table) && window.firstResponder === table
                                Perf.log("escape-start-outline=\(escapeSetup) responder=\(String(describing: window.firstResponder))")
                                // Escape must not invoke a destructive action or clear the current tree.
                                let treeBefore = model.tree, removedBefore = model.lastRemoved.count
                                let pendingBefore = model.pendingRemoval, messageBefore = model.removalMessage
                                DemoInput.key(53, chars: String(UnicodeScalar(27)!))
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                Check.expect("e2-escape-preserves-tree-and-removal-state", escapeSetup && model.tree === treeBefore && model.lastRemoved.count == removedBefore && pendingBefore == nil && messageBefore == nil && model.pendingRemoval == pendingBefore && model.removalMessage == messageBefore)
                                window.makeFirstResponder(table)
                                Check.expect("e2-outline-single-selection-policy", !table.allowsMultipleSelection && table.selectedRowIndexes.count <= 1)
                                // Text editor parity through native editing APIs; IME simulation is not real keyboard IME proof.
                                if let field = model.nameFilterKeyView, window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView {
                                    editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
                                    editor.insertText("edge", replacementRange: editor.selectedRange())
                                    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                                    try? await Task.sleep(nanoseconds: 100_000_000)
                                    Check.expect("name-editor-typing-model-sync", editor.string == "edge" && field.stringValue == "edge" && model.filterText == "edge")
                                    editor.setSelectedRange(NSRange(location: 2, length: 0))
                                    model.filterText = "edge-case"
                                    try? await Task.sleep(nanoseconds: 100_000_000)
                                    Check.expect("name-editor-external-sync-preserves-cursor", editor.string == model.filterText && editor.selectedRange().location == 2 && editor.selectedRange().length == 0)
                                    model.clearFilters()
                                    try? await Task.sleep(nanoseconds: 100_000_000)
                                    Check.expect("name-editor-clear-all-while-editing", editor.string.isEmpty && field.stringValue.isEmpty && model.filterText.isEmpty && editor.selectedRange().location == 0)
                                    editor.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
                                    let marked = editor.hasMarkedText()
                                    editor.unmarkText()
                                    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                                    try? await Task.sleep(nanoseconds: 100_000_000)
                                    Check.expect("name-editor-marked-text-commit-simulation", marked && !editor.hasMarkedText() && model.filterText == editor.string && model.filterText == "日本")
                                    editor.setMarkedText("未完", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                                    let markedBeforeClear = editor.hasMarkedText()
                                    model.clearFilters()
                                    try? await Task.sleep(nanoseconds: 150_000_000)
                                    let cancelled = !editor.hasMarkedText() && editor.string.isEmpty && field.stringValue.isEmpty && model.filterText.isEmpty
                                    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                                    Check.expect("name-editor-external-clear-cancels-marked-text", markedBeforeClear && cancelled && model.filterText.isEmpty, "manual delegate current-field simulation, not delayed IME insertion")
                                    model.clearFilters()
                                    let consumedDeadline = Date().addingTimeInterval(3)
                                    while model.nameEditorConsumedReset != model.filterResetRevision && Date() < consumedDeadline { try? await Task.sleep(nanoseconds: 10_000_000) }
                                    let resetConsumed = model.nameEditorConsumedReset == model.filterResetRevision
                                    let alreadyEmptyModel = model.filterText.isEmpty && editor.string.isEmpty && field.stringValue.isEmpty
                                    editor.setMarkedText("再", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
                                    Perf.log("same-value-fixture-start editor=\(editor.string.debugDescription) field=\(field.stringValue.debugDescription) model=\(model.filterText.debugDescription) reset=\(model.filterResetRevision) consumed=\(model.nameEditorConsumedReset) updates=\(model.nameEditorUpdateCount)")
                                    let emptyMarked = editor.hasMarkedText()
                                    let markedDivergence = editor.hasMarkedText() && editor.string == "再" && field.stringValue == "再" && alreadyEmptyModel && model.filterText.isEmpty
                                    // Exercise an ordinary edit-origin update while marked; no reset intent.
                                    let updatesBefore = model.nameEditorUpdateCount
                                    let resetBefore = model.filterResetRevision, externalBefore = model.externalFilterTextRevision
                                    model.setFilterTextFromEditor(model.filterText)
                                    model.nameEditorRefreshRevision &+= 1
                                    let updateDeadline = Date().addingTimeInterval(3)
                                    while model.nameEditorUpdateCount == updatesBefore && Date() < updateDeadline { try? await Task.sleep(nanoseconds: 10_000_000) }
                                    Check.expect("name-editor-ordinary-update-preserves-marked-text", resetConsumed && model.nameEditorUpdateCount > updatesBefore && model.filterResetRevision == resetBefore && model.externalFilterTextRevision == externalBefore && emptyMarked && editor.hasMarkedText() && editor.string.contains("再"))
                                    @MainActor func resetDiagnostic(_ phase: String) -> String {
                                        "\(phase) alreadyEmptyModel=\(alreadyEmptyModel) markedDivergence=\(markedDivergence) initialMarked=\(emptyMarked) marked=\(editor.hasMarkedText()) editor=\(editor.string.debugDescription) field=\(field.stringValue.debugDescription) model=\(model.filterText.debugDescription) resetRevision=\(model.filterResetRevision) consumedReset=\(model.nameEditorConsumedReset) externalRevision=\(model.externalFilterTextRevision) updateCount=\(model.nameEditorUpdateCount)"
                                    }
                                    Perf.log(resetDiagnostic("before-same-value-clear"))
                                    let resetUpdatesBefore = model.nameEditorUpdateCount
                                    model.clearFilters()
                                    let sameValueDeadline = Date().addingTimeInterval(3)
                                    while (model.nameEditorConsumedReset != model.filterResetRevision || model.nameEditorUpdateCount == resetUpdatesBefore) && Date() < sameValueDeadline { try? await Task.sleep(nanoseconds: 10_000_000) }
                                    let sameValueConsumed = model.nameEditorConsumedReset == model.filterResetRevision && model.nameEditorUpdateCount > resetUpdatesBefore
                                    Check.expect("name-editor-already-empty-reset-with-marked-divergence", sameValueConsumed && alreadyEmptyModel && markedDivergence && emptyMarked && !editor.hasMarkedText() && editor.string.isEmpty && field.stringValue.isEmpty && model.filterText.isEmpty, "consumed=\(sameValueConsumed) \(resetDiagnostic("after-same-value-clear"))")
                                } else {
                                    for name in ["name-editor-ordinary-update-preserves-marked-text", "name-editor-already-empty-reset-with-marked-divergence", "name-editor-external-clear-cancels-marked-text", "name-editor-typing-model-sync", "name-editor-external-sync-preserves-cursor", "name-editor-clear-all-while-editing", "name-editor-marked-text-commit-simulation"] { Check.expect(name, false, "active native editor unavailable") }
                                }
                            } else {
                                Check.expect("e2-explicit-backtab-named-boundary", false, "table missing")
                                BoundaryGuardRegression.recordMissing("table missing")
                                Check.expect("e2-tab-leaves-outline-without-selection-change", false, "table missing")
                                Check.expect("e2-shift-tab-returns-to-outline", false, "table missing")
                                Check.expect("e2-escape-preserves-tree-and-removal-state", false, "table missing")
                                Check.expect("e2-outline-single-selection-policy", false, "table missing")
                                for name in ["name-editor-ordinary-update-preserves-marked-text", "name-editor-already-empty-reset-with-marked-divergence", "name-editor-external-clear-cancels-marked-text", "name-editor-typing-model-sync", "name-editor-external-sync-preserves-cursor", "name-editor-clear-all-while-editing", "name-editor-marked-text-commit-simulation"] { Check.expect(name, false, "table missing") }
                            }
                            // Actual SwiftUI zero-area and no-match screens on a disposable root.
                            let zeroRoot = FileManager.default.temporaryDirectory.appendingPathComponent("spz-zero-view-\(UUID().uuidString)")
                            try? FileManager.default.createDirectory(at: zeroRoot, withIntermediateDirectories: true)
                            FileManager.default.createFile(atPath: zeroRoot.appendingPathComponent("visible-zero.pdf").path, contents: Data())
                            model.clearFilters(); model.scan(zeroRoot.path)
                            let zeroDeadline = Date().addingTimeInterval(10)
                            while model.scanning && Date() < zeroDeadline { try? await Task.sleep(nanoseconds: 20_000_000) }
                            model.filterExt = "pdf"; model.tab = .treemap
                            while model.filterPending && Date() < zeroDeadline { try? await Task.sleep(nanoseconds: 20_000_000) }
                            try? await Task.sleep(nanoseconds: 700_000_000)
                            Check.expect("zero-area-view-fixture-ready", !model.scanning && !model.filterPending && model.activeFilter?.count(model.displayedRoot) == 1 && model.activeFilter?.size(model.displayedRoot) == 0, "pixels37 required")
                            mark(37)
                            model.filterExt = "no-extension-match"
                            while model.filterPending && Date() < zeroDeadline { try? await Task.sleep(nanoseconds: 20_000_000) }
                            try? await Task.sleep(nanoseconds: 700_000_000)
                            Check.expect("no-match-view-fixture-ready", !model.filterPending && model.activeFilter?.count(model.displayedRoot) == 0, "pixels38 required")
                            mark(38)
                            // Preserve37/38, then stress footer presentation with explicit simulated warnings.
                            model.filterExt = "pdf"
                            let footerDeadline = Date().addingTimeInterval(5)
                            while model.filterPending && Date() < footerDeadline { try? await Task.sleep(nanoseconds: 20_000_000) }
                            model.demoFooterUnreadable = 1_234_567; model.demoFooterPartial = true
                            try? await Task.sleep(nanoseconds: 700_000_000)
                            Check.expect("footer-simultaneous-warning-presentation-ready", !model.filterPending && model.activeFilter?.totalCount == 1 && model.demoFooterUnreadable == 1_234_567 && model.demoFooterPartial == true, "pixels39 required; partial/unreadable presentation simulation, not permission/cancel accounting")
                            mark(39)
                            // A separate constrained surface exercises the production footer without shrinking the app below its minimum.
                            let priorProductWindow = DemoInput.window
                            let footerWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 110), styleMask: [.titled], backing: .buffered, defer: false)
                            footerWindow.isReleasedWhenClosed = false
                            footerWindow.title = "CI constrained production footer (700 pt)"
                            let footerHost = NSHostingView(rootView: VStack(spacing: 0) {
                                Text("Production footer at 700 pt; simulated warnings").font(.caption).padding(12)
                                Spacer(minLength: 0)
                                StatusBar(demoDetailsCaptured: { details in
                                    try? details.write(toFile: "/tmp/spz-footer-ax-expected.txt", atomically: true, encoding: .utf8)
                                }).environment(model)
                            }.frame(width: 700, height: 110))
                            footerWindow.contentView = footerHost
                            footerWindow.center(); footerWindow.makeKeyAndOrderFront(nil)
                            try? await Task.sleep(nanoseconds: 700_000_000)
                            let footerSurfaceValid = footerWindow.isVisible && footerWindow.isKeyWindow && abs(footerHost.bounds.width - 700) < 1
                            Check.expect("footer-constrained-production-surface-ready", footerSurfaceValid && model.activeFilter?.totalCount == 1 && model.demoFooterUnreadable == 1_234_567 && model.demoFooterPartial == true, "pixels40 decide natural ViewThatFits branch/accounting; separate700ptsurface not mainwindowbelowminimum; warning simulation")
                            Perf.log("footer-constrained surfaceWidth=\(footerHost.bounds.width) filterCount=\(model.activeFilter?.totalCount ?? 0) unreadable=\(model.demoFooterUnreadable ?? 0) partial=\(model.demoFooterPartial == true)")
                            let exportDeadline = Date().addingTimeInterval(3)
                            var mountedExport: String? = nil
                            while Date() < exportDeadline {
                                mountedExport = try? String(contentsOfFile: "/tmp/spz-footer-ax-expected.txt", encoding: .utf8)
                                if let mountedExport, !mountedExport.isEmpty { break }
                                try? await Task.sleep(nanoseconds: 20_000_000)
                            }
                            if let mountedExport, !mountedExport.isEmpty {
                                try? "\(ProcessInfo.processInfo.processIdentifier)".write(toFile: "/tmp/spz-footer-ax-ready", atomically: true, encoding: .utf8)
                            }
                            let axDeadline = Date().addingTimeInterval(20)
                            while !FileManager.default.fileExists(atPath: "/tmp/spz-footer-ax-ack") && Date() < axDeadline { try? await Task.sleep(nanoseconds: 20_000_000) }
                            Perf.log("footer-ax external-diagnostic acknowledged=\(FileManager.default.fileExists(atPath: "/tmp/spz-footer-ax-ack"))")
                            let externalResult = try? String(contentsOfFile: "/tmp/spz-footer-ax-result.txt", encoding: .utf8)
                            let expectedDetails = try? String(contentsOfFile: "/tmp/spz-footer-ax-expected.txt", encoding: .utf8)
                            let expectedScan = model.lastScanSeconds.map { "Scanned in \(String(format: "%.2f", $0)) seconds" }
                            let expectedFilter = model.activeFilter.map { "Filter: \(formatBytes($0.totalBytes)), 1 file, \(String(format: "%.1f", model.filterMillis)) milliseconds" }
                            let expectedFixture = expectedDetails?.components(separatedBy: "\n").first == model.rootPath && expectedDetails?.contains("Zero KB in 1 item") == true && expectedDetails?.contains("Stopped early, partial accounting") == true && expectedScan.map { expectedDetails?.contains($0) == true } == true && expectedFilter.map { expectedDetails?.contains($0) == true } == true && model.activeFilter?.totalBytes == 0 && model.activeFilter?.totalCount == 1 && expectedDetails?.contains("1,234,567 locations not readable") == true
                            let clientStatus = try? String(contentsOfFile: "/tmp/spz-footer-ax-status.txt", encoding: .utf8)
                            let freshAck = FileManager.default.fileExists(atPath: "/tmp/spz-footer-ax-ack")
                            Check.expect("footer-external-same-node-help-value-exact-details", expectedFixture && freshAck && clientStatus == "EXIT_0" && externalResult == "VERIFIED", "external verified window/PID/role same-node exact UTF8 Help+Value; successful process exit required; denied/error/timeout/truncation is not a pass; native failed gate separate")
                            let footerAX = FooterAXEvidence.inspect(footerWindow)
                            let fullLabel = footerAX.entries.contains { $0.label.contains("Stopped early, partial accounting") && $0.label.contains("Filter:") && $0.label.contains("1 file") && $0.label.contains("1,234,567 locations not readable") && $0.label.contains("Scanned in") }
                            Check.expect("footer-native-accessibility-full-details", fullLabel, "native accessor from mixed AX/view discovery only; not external client reachability; truncated=\(footerAX.truncated); missing label inconclusive when truncated; not VoiceOver/client announcements or tooltip proof")
                            mark(40)
                            footerWindow.close(); priorProductWindow?.makeKeyAndOrderFront(nil)
                            model.demoFooterUnreadable = nil; model.demoFooterPartial = nil
                            await TreemapMountedRegression.run(capture: mark)
                            await TreemapMountedTreeSwapRegression.run(capture: mark)
                            await TreemapMountedFilterRegression.run(capture: mark)
                            await TreemapUnmountRegression.run(capture: mark)
                            try? FileManager.default.removeItem(at: zeroRoot)
                            try? Data().write(to: URL(fileURLWithPath: "/tmp/spz-demo-finished"))

                        } catch {
                            Check.expect("counts-hidden-below-400", false, "fixture error: \(error)")
                            Check.expect("counts-visible-above-400-empty-large-deep", false, "fixture error: \(error)")
                            mark(21); try? await Task.sleep(nanoseconds: 4_000_000_000); mark(22)
                        }
                    }
                    #endif
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
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                if t == .leftMouseDown { InteractionTrace.willPost(e) }
                NSApp.postEvent(e, atStart: false)
                if t == .leftMouseDown { InteractionTrace.record("leftMouseDown-post-after") }
            }
        }
    }
    static func move(fromTop y: CGFloat, x: CGFloat) {
        guard let w = window else { return }
        let p = NSPoint(x: x, y: w.frame.height - y)
        if let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { NSApp.postEvent(e, atStart: false) }
    }
    static func key(_ code: UInt16, chars: String? = nil, modifiers: NSEvent.ModifierFlags = []) {
        guard let w = window else { return }
        let plain = chars ?? (code == 125 ? String(UnicodeScalar(NSDownArrowFunctionKey)!) : "")
        let ch = code == 48 && modifiers.contains(.shift) ? String(UnicodeScalar(NSBackTabCharacter)!) : plain
        // AppKit preserves Shift in charactersIgnoringModifiers.
        let ignoring = code == 48 ? ch : plain
        if code == 48 { Perf.log("native-tab injected code=\(code) modifiers=\(modifiers.rawValue) chars=\(ch.debugDescription) ignoring=\(ignoring.debugDescription)") }
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ignoring,
                                        isARepeat: false, keyCode: code) {
                if t == .keyDown { InteractionTrace.willPost(e) }
                NSApp.postEvent(e, atStart: false)
                if t == .keyDown { InteractionTrace.record("keyDown-post-after") }
            }
        }
    }
}

#if SPZ_CI_TESTS
/// CI-only: pass/fail assertions, written to their own file so evidence never depends on log truncation.
@MainActor enum Check {
    /// In-memory copy of every result, used by the CI ordering driver to verify the run itself (not only the file).
    static var results: [(name: String, ok: Bool)] = []
    /// Where assertions are written. The ordering driver points this at a unique per-run directory; the UI-calibration
    /// job keeps the historical path.
    static var path = "/tmp/spz-assertions.txt"
    /// Non-result diagnostic line ("NOTE ..."), written to the same assertions file; never counted as a check.
    static func note(_ text: String) {
        let url = URL(fileURLWithPath: path)
        let data = "NOTE \(text)\n".data(using: .utf8)!
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
    }
    static func expect(_ name: String, _ ok: Bool, _ detail: String = "") {
        results.append((name, ok))
        let line = "\(ok ? "PASS" : "FAIL") \(name) \(detail)\n"
        let url = URL(fileURLWithPath: path)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() } else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        Perf.log("check \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}


#endif
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

#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
/// Holds exactly one computed publication until the newer operation has completed.
/// Token-specific completion proves the old main-actor closure ran, rather than relying on sleeps.
private actor PublicationBarrier {
    let stage: String
    private var token: UUID?
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    private var released = false
    init(_ stage: String) { self.stage = stage }
    func before(_ stage: String, _ generation: UInt64, _ publication: UUID) async {
        guard !released, stage == self.stage, token == nil else { return }
        token = publication
        await withCheckedContinuation { continuation = $0 }
    }
    func after(_ stage: String, _ generation: UInt64, _ publication: UUID) {
        if stage == self.stage && publication == token { finished = true }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
    func parked() -> Bool { continuation != nil }
    func heldToken() -> UUID? { token }
    func completed() -> Bool { finished }
}

/// Free (nonisolated) so a @Sendable test reviewer can call it. Builds the answer a reviewer would return for (tree, id, version).
private func reviewTestAnswer(_ tree: Tree, _ id: UInt32, _ v: UInt64) -> ItemReviewResult {
    ItemReviewResult(treeID: ObjectIdentifier(tree), node: id, treeVersion: v, path: "node-\(id)", verdict: .same, live: nil)
}

@MainActor private enum PublicationRegression {
    /// A scanned model is READY only when the scan finished and every published surface is current, and that stays true for
    /// several consecutive polls. Run 37164951533 showed a removal refused with "The filter is still updating" right after a
    /// scan: waiting for !scanning alone (or one poll of !filterPending) is not a readiness condition.
    /// Returns the seconds it took to become ready, or nil if it never did (so transient setup lag is distinguishable from a
    /// stuck filterPending in the check detail).
    static func ready(_ m: AppModel) async -> Double? {
        let start = Date()
        let deadline = start.addingTimeInterval(10)
        var stable = 0
        while Date() < deadline {
            let ok = !m.scanning && m.tree != nil && !m.filterPending && !m.rowsPending && m.requiredVersion == nil && !m.viewOutOfDate
                && m.outlineVersion == m.tree?.version && m.derivedVersion == m.tree?.version
            stable = ok ? stable + 1 : 0
            if stable >= 5 { return Date().timeIntervalSince(start) }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }
    /// After a removal commit lands, the outline and derived surfaces publish by themselves but the layout surface needs a
    /// view (there is none in this model-level driver), so the model keeps requiredVersion set and rowsPending true. The
    /// suite acts as the missing view exactly once per settled removal, then requires a quiet model before the next action.
    /// Returns false (and the caller's check will fail on its own conditions) if the model never goes quiet.
    static func settleSurfaces(_ m: AppModel) async -> Bool {
        _ = await m.settleRemoval()
        _ = await wait { !m.removalInFlight && m.commitsInFlight == 0 && m.outlineVersion == m.tree?.version && m.derivedVersion == m.tree?.version }
        if let v = m.tree?.version { m.layoutPublished(v) }
        let quiet = await wait { !m.rowsPending }
        if !quiet { Check.note("settleSurfaces: model never quiet: mutationPending=\(m.mutationPending) commits=\(m.commitsInFlight) required=\(String(describing: m.requiredVersion))") }
        return quiet
    }
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

/// Removal runs its filesystem call off the main actor. These checks use the mocked Trash seam only; no real file is touched.
@MainActor private enum AsyncRemovalRegression {
    static func run() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("spz-async-rm-\(UUID().uuidString)")
        let other = fm.temporaryDirectory.appendingPathComponent("spz-async-rm2-\(UUID().uuidString)")
        for d in [root, other] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        fm.createFile(atPath: root.appendingPathComponent("a.bin").path, contents: Data(repeating: 1, count: 100_000))
        fm.createFile(atPath: root.appendingPathComponent("b.bin").path, contents: Data(repeating: 2, count: 100_000))
        fm.createFile(atPath: root.appendingPathComponent("restore-me.bin").path, contents: Data(repeating: 4, count: 80_000))
        fm.createFile(atPath: other.appendingPathComponent("c.bin").path, contents: Data(repeating: 3, count: 50_000))
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: other) }
        func scan(_ m: AppModel, _ dir: URL) async {
            // Readiness applies to a clean model only; a deliberate rescan during a move/out-of-date state is not "ready" by design.
            let clean = !m.mutationPending && !m.removalInFlight && !m.viewOutOfDate
            m.scan(dir.path)
            let deadline = Date().addingTimeInterval(10)
            while m.scanning && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
            // A removal right after a scan was refused ("filter still updating"). An unready clean model is an explicit FAILED
            // check (never a silent skip), so no later result can pass vacuously on a refused removal.
            if !clean { Check.note("async-removal scan: not-clean rescan (mutationPending=\(m.mutationPending) removalInFlight=\(m.removalInFlight) outOfDate=\(m.viewOutOfDate)); readiness wait skipped by design for \(dir.lastPathComponent)") }
            else if let secs = await PublicationRegression.ready(m) { Check.note("async-removal scan: ready after \(String(format: "%.3f", secs))s for \(dir.lastPathComponent)") }
            else {
                Check.expect("async-removal-fixture", false, "scan of \(dir.lastPathComponent) never reached a ready model within 10s: filterPending=\(m.filterPending) rowsPending=\(m.rowsPending) required=\(String(describing: m.requiredVersion)) outOfDate=\(m.viewOutOfDate)")
            }
        }
        func node(_ m: AppModel, _ name: String) -> UInt32? {
            guard let t = m.tree else { return nil }
            return (0..<UInt32(t.nodeCount)).first(where: { t.name($0) == name })
        }
        let m = AppModel(); await scan(m, root)
        guard let a = node(m, "a.bin"), let b = node(m, "b.bin"), let t0 = m.tree else {
            Check.expect("async-removal-fixture", false, "fixture missing"); return
        }
        let rootSize = t0.info(0).size

        // 1. The slow filesystem call does not block the main actor, and repeat requests are refused while it runs.
        let counter = CallCounter()   // the mock runs on a background task: a plain captured var would be a data race
        m.trashItem = { url in counter.bump(); Thread.sleep(forTimeInterval: 0.4); return url }
        m.proposeRemoval(of: a); m.confirmRemoval()
        let inFlight = m.removalInFlight
        let t = Date()
        try? await Task.sleep(nanoseconds: 50_000_000)   // main actor must be free to resume this promptly
        let responsive = Date().timeIntervalSince(t) < 0.3 && m.removalInFlight
        m.proposeRemoval(of: b)
        let refused = m.pendingRemoval == nil && m.removalMessage != nil
        await m.settleRemoval()
        Check.expect("async-removal-main-actor-stays-responsive", inFlight && responsive && refused && counter.value == 1 && !m.removalInFlight, "inFlight=\(inFlight) responsive=\(responsive) refused=\(refused) calls=\(counter.value)")
        Check.expect("async-removal-forgets-after-success", m.tree?.info(0).size == rootSize - t0.info(a).size || m.tree?.info(a).size == 0, "root=\(m.tree?.info(0).size ?? 0)")

        _ = await PublicationRegression.settleSurfaces(m)   // act as the missing view so the next removal is not paused by the layout surface
        // 2. A failure with the original still present leaves the tree, epoch and journal untouched and reports THAT error
        // (a blocked-commit message must not satisfy this check).
        m.removalMessage = nil
        let before = m.tree?.info(0).size, rev = m.revision, epoch0 = m.fsEpoch, journal0 = m.lastRemoved.count
        m.trashItem = { _ in throw CocoaError(.fileWriteNoPermission) }
        m.proposeRemoval(of: b); m.confirmRemoval(); await m.settleRemoval()
        let msg2 = m.removalMessage ?? ""
        Check.expect("async-removal-failure-leaves-tree-untouched", m.tree?.info(0).size == before && m.revision == rev && m.fsEpoch == epoch0 && m.lastRemoved.count == journal0 && msg2.hasPrefix("Could not move it to the Trash") && !msg2.contains("no longer at its original") && !m.removalInFlight && !m.mutationPending && !m.viewOutOfDate, "message=\(msg2)")

        // 2b. The Trash reports an error but the original is gone anyway: say so, bump the epoch, mark out of date.
        m.removalMessage = nil
        let epoch1 = m.fsEpoch
        let bURL = root.appendingPathComponent("b.bin")
        m.trashItem = { url in try? FileManager.default.removeItem(at: url); throw CocoaError(.fileWriteUnknown) }
        m.proposeRemoval(of: b); m.confirmRemoval(); await m.settleRemoval()
        Check.expect("async-removal-vanished-original-reported-and-marked-out-of-date", (m.removalMessage ?? "").contains("no longer at its original location") && m.fsEpoch == epoch1 + 1 && m.viewOutOfDate && !FileManager.default.fileExists(atPath: bURL.path), "message=\(m.removalMessage ?? "nil") outOfDate=\(m.viewOutOfDate)")
        _ = FileManager.default.createFile(atPath: bURL.path, contents: Data(repeating: 2, count: 100_000))
        m.viewOutOfDate = false; m.outOfDateReason = nil

        // 3. A rescan that swaps the tree mid-move must not forget on the new tree.
        m.removalMessage = nil
        m.trashItem = { url in Thread.sleep(forTimeInterval: 0.4); return url }
        m.proposeRemoval(of: b); m.confirmRemoval()
        await scan(m, other)
        let swapped = m.tree
        let otherSize = swapped?.info(0).size
        await m.settleRemoval()
        Check.expect("async-removal-tree-swapped-mid-move-skips-forget", m.tree === swapped && m.tree?.info(0).size == otherSize && (m.removalMessage ?? "").contains("rescanned") && m.fsEpoch > 0 && !m.mutationPending && !m.removalInFlight, "message=\(m.removalMessage ?? "nil") epoch=\(m.fsEpoch) outOfDate=\(m.viewOutOfDate)")

        // 4. Undo: collision keeps the entry; a clean restore clears it.
        m.lastRemoved = [RemovedItem(original: root.appendingPathComponent("b.bin"), trashed: root.appendingPathComponent("gone.bin"), size: 1)]
        m.undoRemoval(); await m.settleRemoval()
        Check.expect("async-undo-collision-keeps-entry-and-overwrites-nothing", m.lastRemoved.count == 1 && (m.removalMessage ?? "").contains("already exists") && !m.removalInFlight)
        let parked = root.appendingPathComponent("parked.bin"), home = root.appendingPathComponent("restored.bin")
        fm.createFile(atPath: parked.path, contents: Data([1]))
        m.lastRemoved = [RemovedItem(original: home, trashed: parked, size: 1)]
        m.undoRemoval(); await m.settleRemoval()
        Check.expect("async-undo-restores-and-clears-entry", fm.fileExists(atPath: home.path) && !fm.fileExists(atPath: parked.path) && m.lastRemoved.isEmpty)

        // 5. Undo is refused while the engine commit for the removal is parked (filesystem outcome done, table not yet
        // swapped); once the commit lands it is allowed and leaves the view out of date. Mocked Trash only.
        let m2 = AppModel(); await scan(m2, root)
        if let b2 = node(m2, "b.bin") {
            let gate = OpenGate()
            m2.trashItem = { url in url }   // pretend moved; the file stays, so this exercises ordering only
            defer { gate.open() }   // never leave the commit parked if a check below fails early
            m2.beforeCommit = { while !gate.isOpen { try? await Task.sleep(nanoseconds: 5_000_000) } }
            m2.proposeRemoval(of: b2); m2.confirmRemoval()
            let parkedOK = await PublicationRegression.wait { m2.commitsInFlight == 1 && !m2.removalInFlight }
            let journaled = m2.lastRemoved.count == 1
            let items0 = m2.lastRemoved
            m2.undoRemoval()
            let refused = (m2.removalMessage ?? "").contains("still being applied") && m2.lastRemoved.map(\.original) == items0.map(\.original) && m2.lastRemoved.map(\.trashed) == items0.map(\.trashed) && items0.first?.original.lastPathComponent == "b.bin" && !m2.removalInFlight
            gate.open()
            let settled = await m2.settleRemoval()
            Check.expect("async-undo-refused-while-commit-parked", parkedOK && journaled && refused && settled && m2.commitsInFlight == 0, "parked=\(parkedOK) journaled=\(journaled) refused=\(refused) settled=\(settled)")
            // After the commit has landed, undo is ATTEMPTED (not refused as in-progress). The mock left the file in place,
            // so the attempt ends as a collision and the journal entry is kept.
            _ = await PublicationRegression.settleSurfaces(m2)
            m2.removalMessage = nil
            m2.undoRemoval(); await m2.settleRemoval()
            let msg = m2.removalMessage ?? ""
            Check.expect("async-undo-attempted-after-commit-lands", !msg.contains("still being applied") && msg.contains("already exists") && m2.lastRemoved.count == 1, "message=\(msg)")
        } else { Check.expect("async-undo-refused-while-commit-parked", false, "fixture") }

        // 5b. The engine commit for a removal answers BUSY or STALE (an old commit losing to a newer table, or a busy writer):
        // the file move already happened, so the view must go persistently out of date with an honest message, the journal
        // keeps the entry (undo still possible), and no flag stays stuck.
        for (label, status) in [("busy", EngineStatus.busy), ("stale", EngineStatus.stale)] {
            let m5 = AppModel(); await scan(m5, root)
            if let b5 = node(m5, "b.bin") {
                m5.trashItem = { url in url }
                m5.commitOverride = { _, _ in status }
                m5.proposeRemoval(of: b5); m5.confirmRemoval()
                let settled5 = await m5.settleRemoval()
                let msg5 = m5.removalMessage ?? ""
                Check.expect("async-removal-commit-\(label)-marks-out-of-date-and-keeps-journal", settled5 && m5.viewOutOfDate && msg5.contains("could not be updated") && m5.lastRemoved.count == 1 && !m5.mutationPending && !m5.removalInFlight && m5.commitsInFlight == 0, "settled=\(settled5) outOfDate=\(m5.viewOutOfDate) message=\(msg5)")
            } else { Check.expect("async-removal-commit-\(label)-marks-out-of-date-and-keeps-journal", false, "fixture") }
        }

        // 6. A real (temp-dir) move, then a rescan replaces the tree, then undo: the file comes back on disk, the journal
        // is cleared, and the view stays marked out of date (the engine cannot add a subtree back).
        let m3 = AppModel(); await scan(m3, root)
        if let c3 = node(m3, "restore-me.bin") {
            let bin = fm.temporaryDirectory.appendingPathComponent("spz-fake-trash-\(UUID().uuidString)"); try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: bin) }
            m3.trashItem = { url in let dest = bin.appendingPathComponent(url.lastPathComponent); try FileManager.default.moveItem(at: url, to: dest); return dest }
            m3.proposeRemoval(of: c3); m3.confirmRemoval(); _ = await m3.settleRemoval()
            let moved = !fm.fileExists(atPath: root.appendingPathComponent("restore-me.bin").path) && m3.lastRemoved.count == 1
            await scan(m3, root)   // tree replaced after the move
            // scan completion alone does not clear pending state: wait for presentation readiness before undo
            let ready = await PublicationRegression.wait { !m3.scanning && !m3.rowsPending && !m3.filterPending && m3.requiredVersion == nil && m3.outlineVersion == m3.tree?.version }
            m3.undoRemoval(); _ = await m3.settleRemoval()
            let restoredData = try? Data(contentsOf: root.appendingPathComponent("restore-me.bin"))
            let back = ready && restoredData?.count == 80_000 && restoredData?.allSatisfy({ $0 == 4 }) == true
            Check.expect("async-undo-after-rescan-restores-and-marks-out-of-date", moved && back && m3.lastRemoved.isEmpty && m3.viewOutOfDate, "moved=\(moved) back=\(back) journal=\(m3.lastRemoved.count) outOfDate=\(m3.viewOutOfDate)")
        } else { Check.expect("async-undo-after-rescan-restores-and-marks-out-of-date", false, "fixture") }

        // 7. Cancelling the removal task mid-move is harmless: it does NOT stop the move (the detached task finishes), and the
        // outcome is still journaled with the flags cleared. This asserts that behavior; it is not cancellation support.
        let m4 = AppModel(); await scan(m4, root)
        if let a4 = node(m4, "a.bin") {
            m4.trashItem = { url in Thread.sleep(forTimeInterval: 0.3); return url }
            m4.proposeRemoval(of: a4); m4.confirmRemoval()
            m4.removalTask?.cancel()
            let settled = await m4.settleRemoval()
            Check.expect("async-removal-cancel-is-harmless-and-does-not-stop-the-move", settled && m4.lastRemoved.count == 1 && !m4.removalInFlight && !m4.mutationPending && m4.commitsInFlight == 0, "settled=\(settled) journal=\(m4.lastRemoved.count) inFlight=\(m4.removalInFlight) pending=\(m4.mutationPending)")
        } else { Check.expect("async-removal-cancel-is-harmless-and-does-not-stop-the-move", false, "fixture") }
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
            Check.expect("zero-match-root-count-and-layout-data-contract", false, "fixture missing")
            return
        }
        m.filterExt = "pdf"
        while m.filterPending && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        let calls = CallCounter()
        m.trashItem = { url in calls.bump(); return url }
        let visible = m.activeFilter?.count(zero) == 1 && m.activeFilter?.size(zero) == 0 && !m.isOutsideFilter(zero) && m.removalBlockedReason(zero) == nil
        let emptyLayout = tree.layout(root: 0, size: CGSize(width: 400, height: 400), filter: m.activeFilter)
        Check.expect("zero-match-root-count-and-layout-data-contract", m.activeFilter?.count(0) == 1 && emptyLayout.rects.isEmpty && m.activeFilter?.count(hidden) == 0, "rootMatches=\(m.activeFilter?.count(0) ?? 0) rects=\(emptyLayout.rects.count)")
        m.proposeRemoval(of: hidden)
        let hiddenBlocked = m.pendingRemoval == nil && calls.value == 0
        m.removalMessage = nil
        m.proposeRemoval(of: zero)
        let opened = m.pendingRemoval == zero && calls.value == 0
        m.confirmRemoval(); await m.settleRemoval()
        Check.expect("zero-match-selection-removal-policy", visible && hiddenBlocked && opened && calls.value == 1, "visible=\(visible) hiddenBlocked=\(hiddenBlocked) opened=\(opened) mockedCalls=\(calls.value)")
    }
}


/// Forced-order checks for removal commits. Source-only until a Mac build runs them (not compiled in the Linux sandbox).
@MainActor private enum CommitOrderingRegression {
    private static func fixture() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spz-commit-\(UUID().uuidString)")
        let fm = FileManager.default
        try? fm.createDirectory(at: root.appendingPathComponent("dirA/sub"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("dirB"), withIntermediateDirectories: true)
        for (n, k) in [("dirA/sub/deep.txt", 40_000), ("dirA/a.txt", 20_000), ("dirB/b.txt", 30_000), ("c.txt", 10_000)] {
            fm.createFile(atPath: root.appendingPathComponent(n).path, contents: Data(repeating: 1, count: k))
        }
        return root
    }
    private static func scanned(_ root: URL) async -> AppModel? {
        let m = AppModel(); m.scan(root.path)
        let readySecs = await PublicationRegression.ready(m)
        if let r = readySecs { Check.note("commit-order scanned(): ready after \(String(format: "%.3f", r))s") }
        guard readySecs != nil else { Check.expect("commit-order-fixture-ready", false, "scanned model never became ready: filterPending=\(m.filterPending) rowsPending=\(m.rowsPending) required=\(String(describing: m.requiredVersion)) outOfDate=\(m.viewOutOfDate)"); return nil }   // explicit failure, never a silent pass
        m.trashItem = { $0 }   // no real file is touched
        return m
    }
    private static func node(_ m: AppModel, _ name: String) -> UInt32? {
        guard let t = m.tree else { return nil }
        return (0..<UInt32(t.nodeCount)).first { t.name($0) == name }
    }
    /// Returns whether the removal was actually ACCEPTED (the move began: removalInFlight is set synchronously by confirmRemoval).
    /// A refusal where acceptance was expected is also an explicit failed check, so no result can pass on a refused removal.
    @discardableResult
    private static func remove(_ m: AppModel, _ id: UInt32, expectAccepted: Bool = true, line: Int = #line) -> Bool {
        m.pendingRemoval = id; m.confirmRemoval()
        let accepted = m.removalInFlight
        if expectAccepted && !accepted { Check.expect("commit-order-removal-accepted", false, "line=\(line) refused: \(m.removalMessage ?? "nil")") }
        return accepted
    }

    static func run() async {
        let root = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        // 1. A filter publication computed on the OLD table and parked BEFORE the removal's engine forget must not publish
        // old numbers afterwards. Order matters: confirmRemoval refuses while a filter is pending, so the removal is ACCEPTED
        // first (its commit parked between the file move and the forget), and only then is the filter parked.
        if let m = await scanned(root), let big = node(m, "dirA") {
            let gate = PublicationBarrier("commit")
            m.beforeCommit = { await gate.before("commit", 0, UUID()) }
            let barrier = PublicationBarrier("filter")
            m.beforePublish = { await barrier.before($0, $1, $2) }
            m.afterPublish = { await barrier.after($0, $1, $2) }
            let treeV0 = m.tree?.version ?? 0
            let acc = remove(m, big)
            let held = await PublicationRegression.wait { await gate.parked() }       // move done, forget not yet applied
            m.filterExt = "txt"                                                        // filter computed on the old version
            let parked = await PublicationRegression.wait { await barrier.parked() }
            let versionStillOld = (m.tree?.version ?? 0) == treeV0                     // the forget has not happened yet
            await gate.release()                                                       // forget applies now
            _ = await PublicationRegression.wait { m.commitsInFlight == 0 }
            await barrier.release()                                                    // late filter publication tries to land
            _ = await PublicationRegression.wait { await barrier.completed() }
            _ = await PublicationRegression.wait { !m.destructiveBlocked && !m.filterPending }
            // Non-vacuous: accepted, both parked before the forget, the table version ADVANCED, and the surviving filter
            // must be present and carry exactly the new version; the old-version publication was not accepted.
            let advanced = (m.tree?.version ?? 0) > treeV0
            let filterOK = m.activeFilter != nil && m.activeFilter?.version == m.tree?.version   // nil is a failure: filterExt "txt" must still be active
            let ok = held && parked && versionStillOld && advanced && filterOK
            Check.expect("commit-order-filter-parked-before-forget-late-publish-rejected", acc && ok, "accepted=\(acc) commitHeld=\(held) filterParked=\(parked) versionStillOldAtPark=\(versionStillOld) treeBefore=\(treeV0) tree=\(m.tree?.version ?? 0) filterVersion=\(m.activeFilter.map { String($0.version) } ?? "nil")")
        } else { Check.expect("commit-order-filter-parked-before-forget-late-publish-rejected", false, "fixture") }

        // 2. A scan that started before a removal and publishes after it is marked out of date.
        if let m = await scanned(root), let id = node(m, "dirB") {
            let barrier = PublicationBarrier("scan-completion")
            m.beforePublish = { await barrier.before($0, $1, $2) }
            m.afterPublish = { await barrier.after($0, $1, $2) }
            m.scan(root.path)
            let parked = await PublicationRegression.wait { await barrier.parked() }
            let acc = remove(m, id)
            await barrier.release()
            _ = await PublicationRegression.wait { await barrier.completed() }
            Check.expect("commit-order-scan-started-before-fs-change-marked-out-of-date", acc && parked && m.viewOutOfDate && m.destructiveBlocked, "accepted=\(acc) parked=\(parked) outOfDate=\(m.viewOutOfDate)")
        } else { Check.expect("commit-order-scan-started-before-fs-change-marked-out-of-date", false, "fixture") }

        // 3. MANUAL tree replacement (m.tree = other, not a scan publication) while a commit is parked: proves only that the
        // outcome is marked and not dropped. It does not prove actual scan publication behavior or new-tree invariants (see 3b).
        // 4. Undo during a commit is refused and leaves the journal.
        if let m = await scanned(root), let id = node(m, "dirB") {
            let gate = PublicationBarrier("commit")
            m.beforeCommit = { await gate.before("commit", 0, UUID()) }
            let acc = remove(m, id)
            let held = await PublicationRegression.wait { await gate.parked() }
            m.undoRemoval()
            let refused = (m.removalMessage ?? "").contains("still being applied") && !m.lastRemoved.isEmpty
            let other = await ScanSession(root: root.path, excludes: [])?.run { _ in }
            let old = m.tree
            m.tree = other
            await gate.release()
            _ = await PublicationRegression.wait { m.commitsInFlight == 0 }
            Check.expect("commit-order-undo-during-commit-refused", acc && held && refused)
            Check.expect("commit-order-replaced-tree-outcome-marked-not-dropped", acc && old !== other && m.viewOutOfDate && (m.removalMessage ?? "").contains("Rescan"), "outOfDate=\(m.viewOutOfDate)")
        } else { Check.expect("commit-order-undo-during-commit-refused", false, "fixture"); Check.expect("commit-order-replaced-tree-outcome-marked-not-dropped", false, "fixture") }

        // 3b. A REAL scan publishes a new tree while a commit is parked between the file move and the engine forget; then
        // the parked commit finishes against the OLD tree. The outcome must be marked, and the new tree's published state
        // must be exactly what the scan published (no forget applied to it, no revision bump, no selection or row change).
        if let m = await scanned(root), let id = node(m, "dirB") {
            let other2 = fixture()
            defer { try? FileManager.default.removeItem(at: other2) }
            let gate = PublicationBarrier("commit")
            m.beforeCommit = { await gate.before("commit", 0, UUID()) }
            let acc = remove(m, id)
            let held = await PublicationRegression.wait { await gate.parked() }
            let oldTree = m.tree
            m.scan(other2.path)
            let published = await PublicationRegression.wait { !m.scanning && m.tree != nil && m.tree !== oldTree && !m.filterPending }
            let newTree = m.tree, newVersion = m.tree?.version, newRevision = m.revision
            let newRows = m.outlineRows.map { $0.node }, newItems = m.progress.items, newBytes = m.progress.bytes
            let newRoot = newTree.map { $0.info(0).size }
            let outOfDateBefore = m.viewOutOfDate
            let commitStillParked = m.commitsInFlight == 1
            await gate.release()
            let settled = await PublicationRegression.wait { m.commitsInFlight == 0 }
            let invariants = m.tree === newTree && m.tree?.version == newVersion && m.revision == newRevision && m.outlineRows.map { $0.node } == newRows && m.progress.items == newItems && m.progress.bytes == newBytes && m.tree.map { $0.info(0).size } == newRoot && !m.scanning
            Check.expect("commit-order-real-scan-published-before-parked-commit-finishes-marks-out-of-date-keeps-new-tree", acc && held && published && commitStillParked && settled && invariants && m.viewOutOfDate && (m.removalMessage ?? "").contains("Rescan") && !m.mutationPending, "held=\(held) published=\(published) parked=\(commitStillParked) settled=\(settled) invariants=\(invariants) outOfDateBeforeRelease=\(outOfDateBefore) outOfDate=\(m.viewOutOfDate)")
        } else { Check.expect("commit-order-real-scan-published-before-parked-commit-finishes-marks-out-of-date-keeps-new-tree", false, "fixture") }

        // 5. Selected, expanded and displayed root inside a removed subtree are reset with the new numbers.
        if let m = await scanned(root), let dir = node(m, "dirA"), let sub = node(m, "sub"), let deep = node(m, "deep.txt") {
            m.expanded = [dir, sub]; m.selected = deep; m.displayedRoot = sub
            let v5 = m.tree?.version ?? 0
            let acc = remove(m, dir)
            _ = await PublicationRegression.wait { !m.removalInFlight && m.commitsInFlight == 0 && (m.tree?.version ?? 0) > v5 }
            _ = await PublicationRegression.settleSurfaces(m)
            Check.expect("commit-order-subtree-state-reset", acc && (m.tree?.version ?? 0) > v5 && m.selected == nil && !m.expanded.contains(dir) && !m.expanded.contains(sub) && m.displayedRoot == 0, "selected=\(String(describing: m.selected)) root=\(m.displayedRoot)")
        } else { Check.expect("commit-order-subtree-state-reset", false, "fixture") }

        // 6. An engine failure after a successful filesystem move marks the view out of date and blocks further removals.
        if let m = await scanned(root), let id = node(m, "c.txt") {
            var overrideCalls = 0
            var trashCalls: [String] = []
            m.trashItem = { trashCalls.append($0.lastPathComponent); return $0 }
            m.commitOverride = { _, _ in overrideCalls += 1; return .mutationFailed }
            let acc = remove(m, id)
            _ = await PublicationRegression.wait { !m.removalInFlight && m.commitsInFlight == 0 }
            let blocked = m.destructiveBlocked
            m.removalMessage = nil
            if let other = node(m, "b.txt") { remove(m, other, expectAccepted: false) }
            // The second removal must be refused before any filesystem call or engine commit.
            let journalIsFirst = m.lastRemoved.first?.original.lastPathComponent == "c.txt"
            Check.expect("commit-order-failure-after-fs-success-persistent-out-of-date", acc && m.viewOutOfDate && blocked && journalIsFirst && trashCalls == ["c.txt"] && overrideCalls == 1, "outOfDate=\(m.viewOutOfDate) trash=\(trashCalls) commits=\(overrideCalls)")
        } else { Check.expect("commit-order-failure-after-fs-success-persistent-out-of-date", false, "fixture") }

        // 7. Surfaces: after a commit, navigation stays blocked until outline, derived AND the layout (treemap tab) all reach
        // the required version; viewOutOfDate blocks removal but not navigation of the old consistent tree.
        if let m = await scanned(root), let id = node(m, "dirB") {
            m.tab = .treemap
            let acc = remove(m, id)
            _ = await PublicationRegression.wait { !m.removalInFlight && m.commitsInFlight == 0 && m.outlineVersion == m.tree?.version && m.derivedVersion == m.tree?.version }
            let layoutLagging = m.navigationBlocked && m.requiredVersion != nil          // layout has not published yet
            m.layoutPublished(m.tree?.version ?? 0)
            let released = !m.navigationBlocked && m.requiredVersion == nil
            m.markOutOfDate("test")
            let destructive = m.destructiveBlocked && !m.navigationBlocked                 // out of date: remove blocked, navigate allowed
            Check.expect("commit-order-all-surfaces-required-before-unblock", acc && layoutLagging && released && destructive, "lag=\(layoutLagging) released=\(released) destructive=\(destructive)")
        } else { Check.expect("commit-order-all-surfaces-required-before-unblock", false, "fixture") }

        // 8. Cells never mix versions: the shown size and node details are published with the rows (same count, same version).
        if let m = await scanned(root) {
            m.filterExt = "txt"
            _ = await PublicationRegression.wait { !m.filterPending && m.outlineVersion == m.tree?.version && m.outlineShown.count == m.outlineRows.count }
            let aligned = m.outlineInfos.count == m.outlineRows.count && m.outlineShown.count == m.outlineRows.count && m.outlineVersion == m.activeFilter?.version
            let sameAsFilter = zip(m.outlineRows, m.outlineShown).allSatisfy { r, sh in m.activeFilter?.size(r.node) == sh }
            Check.expect("commit-order-cell-values-published-with-rows", aligned && sameAsFilter)
        } else { Check.expect("commit-order-cell-values-published-with-rows", false, "fixture") }

        // 9. Scan replacement clears published totals instead of showing the old total with the new count.
        if let m = await scanned(root) {
            let barrier = PublicationBarrier("scan-completion")
            m.beforePublish = { await barrier.before($0, $1, $2) }
            m.afterPublish = { await barrier.after($0, $1, $2) }
            let oldTotal = m.publishedTotalBytes
            m.scan(root.path)
            _ = await PublicationRegression.wait { await barrier.parked() }
            await barrier.release()
            _ = await PublicationRegression.wait { await barrier.completed() }
            // Checked in the same turn the new tree was published: the old total must be gone until the new outline lands.
            Check.expect("commit-order-scan-replacement-clears-published-totals", oldTotal != nil && (m.publishedTotalBytes == nil || m.outlineVersion == m.tree?.version), "total=\(String(describing: m.publishedTotalBytes))")
        } else { Check.expect("commit-order-scan-replacement-clears-published-totals", false, "fixture") }

        // 10. BUSY retries are bounded: the sixth request for the same inputs marks the view out of date; nothing fires meanwhile.
        // 8a. Layout not renderable (view removed / size <= 1) must not hold actions forever. Model-level only; a real view driver is still owed.
        if let m = await scanned(root), let id = node(m, "dirB") {
            m.tab = .treemap
            let acc = remove(m, id)
            _ = await PublicationRegression.wait { !m.removalInFlight && m.commitsInFlight == 0 && m.outlineVersion == m.tree?.version && m.derivedVersion == m.tree?.version }
            let held = m.requiredVersion != nil
            m.layoutNotRenderable()
            Check.expect("commit-order-layout-not-renderable-releases", acc && held && m.requiredVersion == nil && !m.navigationBlocked, "held=\(held) req=\(String(describing: m.requiredVersion))")
        } else { Check.expect("commit-order-layout-not-renderable-releases", false, "fixture") }
        // 8c. Selection/alert numbers come from one capture and are withheld (nil) while rows are pending; removal is blocked then.
        if let m = await scanned(root), let id = node(m, "dirA") {
            let before = m.nodeSnapshot(id)
            m.requiredVersion = m.tree?.version          // simulate "rows pending"
            let during = m.nodeSnapshot(id)
            let blocked = m.removalBlockedReason(id) != nil
            m.requiredVersion = nil
            let after = m.nodeSnapshot(id)
            Check.expect("commit-order-node-snapshot-withheld-while-pending", before != nil && during == nil && blocked && after != nil && after?.version == m.tree?.version, "before=\(before != nil) during=\(during == nil) blocked=\(blocked) after=\(after != nil)")
        } else { Check.expect("commit-order-node-snapshot-withheld-while-pending", false, "fixture") }
        // 8a. Poison: a moved panic counter must refuse actions, node reads, navigation and publication, clear the filter spinner,
        // and stay latched (the baseline is never re-adopted) until a clean rescan.
        if let m = await scanned(root), let id = node(m, "dirB") {
            var fake = m.panicBaseline
            m.panicCounter = { fake }
            let clean = !m.enginePoisoned && m.nodeSnapshot(id) != nil && m.removalBlockedReason(id) == nil
            fake += 1
            let refused = m.enginePoisoned && m.nodeSnapshot(id) == nil && m.removalBlockedReason(id) != nil && m.navigationBlocked
            m.filterPending = true
            m.markPoisoned()
            fake = m.panicBaseline   // counter "returns" to baseline: the latch must hold
            let latched = m.poisoned && m.enginePoisoned && !m.filterPending && m.viewOutOfDate
            Check.expect("poison-latches-refuses-and-clears-spinner", clean && refused && latched, "clean=\(clean) refused=\(refused) latched=\(latched)")
        } else { Check.expect("poison-latches-refuses-and-clears-spinner", false, "fixture") }
        // 8c. A counter bump while a derived publication is parked before its barrier must refuse that publication on release;
        // a counter bump while idle must surface through the bounded watch; the scan baseline is the validated count.
        if let m = await scanned(root) {
            let box = PanicBox(m.panicBaseline)
            m.panicCounter = { box.value }
            _ = await PublicationRegression.wait { m.derivedVersion == m.tree?.version && m.outlineVersion == m.tree?.version }   // initial publications settled first
            let baselineOK = !m.enginePoisoned   // clean right after a scan; adoption of ScanSession.validatedPanicCount itself is NOT asserted here
            let before = m.derivedVersion
            m.beforePublish = { name, _, _ in if name == "derived" { box.value += 1 } }
            m.refreshDerived()
            _ = await PublicationRegression.wait { m.poisoned }
            m.beforePublish = nil
            Check.expect("poison-refuses-parked-derived-publication", baselineOK && m.poisoned && m.derivedVersion == before, "poisoned=\(m.poisoned) derivedMoved=\(m.derivedVersion != before)")
        } else { Check.expect("poison-refuses-parked-derived-publication", false, "fixture") }
        if let m = await scanned(root) {
            let box = PanicBox(m.panicBaseline)
            m.panicCounter = { box.value }
            box.value += 1   // idle: no publication in flight
            let seen = await PublicationRegression.wait { m.poisoned }
            Check.expect("poison-idle-counter-move-observed-by-watch", seen && m.viewOutOfDate, "seen=\(seen)")
        } else { Check.expect("poison-idle-counter-move-observed-by-watch", false, "fixture") }
        // 8d. Selected-node BUSY policy: past 5 fast retries the view stays on a placeholder (nil), the model is NOT marked out
        // of date, and retries continue; a later success clears it; changing the selection cancels the pending retry.
        if let m = await scanned(root), let id = node(m, "dirB"), let other = node(m, "dirA") {
            let busy = BusyFlag(true)
            m.nodeCheckedOverride = { tree, i in
                busy.value ? .failure(.busy) : tree.nodeChecked(i)
            }
            var rounds = 0, last = m.nodeRetryToken
            _ = m.nodeSnapshot(id)
            while rounds < 7 {
                let moved = await PublicationRegression.wait { m.nodeRetryToken != last }
                if !moved { break }
                last = m.nodeRetryToken; rounds += 1
                _ = m.nodeSnapshot(id)   // what the view does on re-render
            }
            let stillPlaceholder = m.nodeSnapshot(id) == nil
            let notEscalated = !m.viewOutOfDate && m.requiredVersion == nil
            busy.value = false
            let last2 = m.nodeRetryToken
            let recovered = await PublicationRegression.wait { m.nodeRetryToken != last2 } && m.nodeSnapshot(id) != nil && !m.retryPending("node")
            busy.value = true
            _ = m.nodeSnapshot(id)
            let pendingBefore = await PublicationRegression.wait { m.retryPending("node") }   // sample only once the retry is actually pending
            m.selected = other   // selection change must cancel the old node's retry
            let cancelled = pendingBefore && !m.retryPending("node")
            Check.expect("node-busy-6plus-placeholder-recovers-and-cancels-on-selection-change", rounds >= 6 && stillPlaceholder && notEscalated && recovered && cancelled, "rounds=\(rounds) placeholder=\(stillPlaceholder) notEscalated=\(notEscalated) recovered=\(recovered) cancelled=\(cancelled) pendingBefore=\(pendingBefore) pendingAfter=\(m.retryPending("node"))")
        } else { Check.expect("node-busy-6plus-placeholder-recovers-and-cancels-on-selection-change", false, "fixture") }
        // 8e. Retry dedupe: three calls with the same inputs while one retry is waiting fire ONE action and consume ONE attempt.
        if let m = await scanned(root) {
            let fired = CallCounter()
            m.retryBusy("dedupe-test", inputs: 7) { fired.bump() }
            m.retryBusy("dedupe-test", inputs: 7) { fired.bump() }
            m.retryBusy("dedupe-test", inputs: 7) { fired.bump() }
            _ = await PublicationRegression.wait { fired.value >= 1 }
            try? await Task.sleep(nanoseconds: 400_000_000)   // a duplicate would have fired by now
            Check.expect("retry-same-inputs-dedupes-to-one-fire", fired.value == 1, "fired=\(fired.value)")
            m.retryDone("dedupe-test")
            // New inputs while a retry is pending REPLACE it: only the second action fires, once, and the count restarts.
            let a = CallCounter(), b = CallCounter()
            m.retryBusy("replace-test", inputs: 7) { a.bump() }
            m.retryBusy("replace-test", inputs: 8) { b.bump() }
            _ = await PublicationRegression.wait { b.value >= 1 }
            try? await Task.sleep(nanoseconds: 400_000_000)
            Check.expect("retry-new-inputs-replace-pending-action", a.value == 0 && b.value == 1, "old=\(a.value) new=\(b.value)")
            m.retryDone("replace-test")
        } else { Check.expect("retry-same-inputs-dedupes-to-one-fire", false, "fixture") }
        // 8b. Deadline must not livelock: repeated publishes of an already-current surface do not reset it; a layout that
        // never lands ends in an explicit out-of-date error after the forced refresh and one extension.
        if let m = await scanned(root), let id = node(m, "dirB") {
            m.pendingStepNanos = 100_000_000
            m.tab = .treemap
            let acc = remove(m, id)
            _ = await PublicationRegression.wait { m.outlineVersion == m.tree?.version && m.derivedVersion == m.tree?.version }
            for _ in 0..<20 { m.surfaceCheck(); try? await Task.sleep(nanoseconds: 30_000_000) }   // same-surface repeats, ~600 ms > 2 steps
            let ended = await PublicationRegression.wait { m.viewOutOfDate }
            Check.expect("commit-order-deadline-terminal-when-layout-missing", acc && ended && m.requiredVersion == nil, "outOfDate=\(m.viewOutOfDate)")
        } else { Check.expect("commit-order-deadline-terminal-when-layout-missing", false, "fixture") }
        // 9. Retry keys include the table version: after a removal (new version) the keys change, so old retries do not eat the new budget.
        if let m = await scanned(root), let id = node(m, "dirB") {
            let k0 = (m.outlineInputKey, m.derivedInputKey, m.filterInputKey, m.layoutInputKey(root: 0, size: CGSize(width: 100, height: 100)))
            let acc = remove(m, id)
            _ = await PublicationRegression.wait { !m.removalInFlight && m.commitsInFlight == 0 }
            let k1 = (m.outlineInputKey, m.derivedInputKey, m.filterInputKey, m.layoutInputKey(root: 0, size: CGSize(width: 100, height: 100)))
            Check.expect("commit-order-retry-keys-change-with-version", acc && k0.0 != k1.0 && k0.1 != k1.1 && k0.2 != k1.2 && k0.3 != k1.3, "outlineChanged=\(k0.0 != k1.0) derivedChanged=\(k0.1 != k1.1) filterChanged=\(k0.2 != k1.2) layoutChanged=\(k0.3 != k1.3) (model-level)")
        } else { Check.expect("commit-order-retry-keys-change-with-version", false, "fixture") }

        if let m = await scanned(root) {
            // Only a retry that actually FIRED counts toward the bound (same-input calls while one waits are deduped, by design),
            // so the view's behavior is modeled: each fired action asks again with the same inputs.
            var firedA = 0
            func again() { m.retryBusy("bound-test", inputs: 1) { firedA += 1; again() } }
            again()
            let escalated = await PublicationRegression.wait { m.viewOutOfDate }
            let afterEscalation = firedA
            try? await Task.sleep(nanoseconds: 800_000_000)   // nothing keeps firing once escalated
            Check.expect("commit-order-busy-retry-bounded", escalated && afterEscalation == 5 && firedA == 5 && !m.retryPending("bound-test"), "escalated=\(escalated) firedAtEscalation=\(afterEscalation) firedLater=\(firedA)")
            var fired = 0
            m.viewOutOfDate = false
            m.retryBusy("bound-test", inputs: 2) { fired += 1 }       // new inputs reset the count
            _ = await PublicationRegression.wait { fired == 1 }
            Check.expect("commit-order-busy-retry-new-inputs-reset", fired == 1 && !m.viewOutOfDate)
        } else { Check.expect("commit-order-busy-retry-bounded", false, "fixture") }
    }
}

/// ACTUAL-VIEW slice 2 (test binary only): the production OutlineView (AppKit NSTableView) mounted in a real NSWindow.
/// Trash is mocked. Rows are read back through the table's own accessibility labels, selection through the real table.
@MainActor private enum MountedOutlineRegression {
    private static func fixture(_ tag: String, _ files: [(String, Int)]) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spz-\(tag)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (n, k) in files { FileManager.default.createFile(atPath: root.appendingPathComponent(n).path, contents: Data(repeating: 7, count: k)) }
        return root
    }
    private static func node(_ t: Tree, _ name: String) -> UInt32? { (0..<UInt32(t.nodeCount)).first { t.name($0) == name } }
    private static func findTable(_ v: NSView) -> NSTableView? {
        if let t = v as? NSTableView { return t }
        for s in v.subviews { if let t = findTable(s) { return t } }
        return nil
    }
    /// Accessibility labels of every row the table can realize right now.
    private static func labels(_ t: NSTableView) -> [String] {
        var out: [String] = []
        for r in 0..<t.numberOfRows {
            if let c = t.view(atColumn: 0, row: r, makeIfNecessary: true) { out.append(c.accessibilityLabel() ?? "") } else { out.append("") }
        }
        return out
    }
    private static func snapshot(_ view: NSView, _ file: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let dir = (Check.path as NSString).deletingLastPathComponent
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: dir + "/" + file)) }
    }
    private static func subviewsDeep(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap { subviewsDeep($0) } }
    /// Visible text of every realized row (all NSTextFields not hidden) plus whether any share bar or chevron is still visible.
    private static func visibleCellState(_ t: NSTableView) -> (texts: [String], barsVisible: Int, chevronsVisible: Int) {
        var texts: [String] = [], bars = 0, chev = 0
        for r in 0..<t.numberOfRows {
            guard let c = t.view(atColumn: 0, row: r, makeIfNecessary: true) else { continue }
            c.layoutSubtreeIfNeeded()
            for v in subviewsDeep(c) {
                if let f = v as? NSTextField, !f.isHidden, !f.stringValue.isEmpty { texts.append(f.stringValue) }
                if String(describing: type(of: v)).contains("ShareBarView"), !v.isHidden { bars += 1 }
                if v is NSButton, !v.isHidden { chev += 1 }
            }
        }
        return (texts, bars, chev)
    }
    private static func hasLabel(_ l: [String], _ name: String) -> Bool { l.contains { $0.hasPrefix(name + ",") } }

    static func run() async {
        let dir = fixture("mounted-outline", [("big.bin", 600_000), ("mid.bin", 250_000), ("small.bin", 90_000), ("tiny.bin", 40_000)])
        defer { try? FileManager.default.removeItem(at: dir) }
        // A folder row, so the unpoisoned positive control can see a chevron.
        let sub = dir.appendingPathComponent("sub")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sub.appendingPathComponent("inner.dat").path, contents: Data(repeating: 7, count: 30_000))
        let m = AppModel(); m.scan(dir.path)
        guard await PublicationRegression.ready(m) != nil, let tree = m.tree, let big = node(tree, "big.bin"), let mid = node(tree, "mid.bin") else {
            Check.expect("view-outline-rows-mounted-match-published", false, "fixture: model never ready"); Check.expect("view-outline-selection-syncs-both-ways", false, "fixture: model never ready"); Check.expect("view-outline-removal-drops-row-and-clears-selection", false, "fixture: model never ready"); Check.expect("view-poison-outline-cells-show-unavailable-not-stale-names", false, "fixture: model never ready"); Check.expect("view-poison-outline-latch-persists-in-mounted-table", false, "fixture: model never ready"); return
        }
        m.trashItem = { $0 }
        m.tab = .kinds   // the default tab is the treemap, which is not mounted here; its layout surface would never publish and the removal gate could not release
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 520, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "CI mounted outline (ordering driver)"
        let host = NSHostingView(rootView: OutlineView().environment(m))
        window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let mounted = await PublicationRegression.wait { if let t = findTable(host) { return t.numberOfRows > 0 && t.numberOfRows == m.outlineRows.count }; return false }
        guard mounted, let table = findTable(host) else {
            Check.expect("view-outline-rows-mounted-match-published", false, "outline table never mounted with published rows"); Check.expect("view-outline-selection-syncs-both-ways", false, "outline table never mounted with published rows"); Check.expect("view-outline-removal-drops-row-and-clears-selection", false, "outline table never mounted with published rows"); Check.expect("view-poison-outline-cells-show-unavailable-not-stale-names", false, "outline table never mounted"); Check.expect("view-poison-outline-latch-persists-in-mounted-table", false, "outline table never mounted"); return
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let l0 = labels(table)
        snapshot(host, "outline-before-removal.png")
        let rowsMatch: Bool = table.numberOfRows == m.outlineRows.count
        let allNames: Bool = ["big.bin", "mid.bin", "small.bin", "tiny.bin"].allSatisfy { hasLabel(l0, $0) }
        let bigSized: Bool = l0.contains { $0.hasPrefix("big.bin,") && $0.contains("item") }
        Check.expect("view-outline-rows-mounted-match-published", rowsMatch && allNames && bigSized, "tableRows=\(table.numberOfRows) published=\(m.outlineRows.count) allNames=\(allNames) labels=\(l0)")

        // Model -> table, then table -> model, through the real NSTableView.
        m.selected = big
        let toTable = await PublicationRegression.wait { if let i = m.outlineIndex[big] { return table.selectedRow == i }; return false }
        let midRow = m.outlineIndex[mid] ?? -1
        table.selectRowIndexes(IndexSet(integer: midRow), byExtendingSelection: false)
        let toModel = await PublicationRegression.wait { m.selected == mid }
        Check.expect("view-outline-selection-syncs-both-ways", toTable && toModel && midRow >= 0, "modelToTable=\(toTable) tableToModel=\(toModel) selected=\(String(describing: m.selected)) selectedRow=\(table.selectedRow)")

        // Real removal flow with the Trash mocked: row disappears from the mounted table, selection must not point at it.
        m.selected = big
        let selectedBeforeRemoval = await PublicationRegression.wait { if let i = m.outlineIndex[big] { return table.selectedRow == i }; return false }
        var lateSync = false
        if !selectedBeforeRemoval { try? await Task.sleep(nanoseconds: 1_000_000_000); if let i = m.outlineIndex[big] { lateSync = table.selectedRow == i } }
        var selDiag = "BASELINE modelSelected=\(String(describing: m.selected)) big=\(big) bigIndex=\(String(describing: m.outlineIndex[big])) tableRow=\(table.selectedRow) lateSync=\(lateSync) coordinator[\(table.accessibilityHelp() ?? "nil")] \(SelDiag.summary)"
        if !selectedBeforeRemoval {
            // Labelled PROBES, run only after the baseline above was captured; they never feed the precondition. Each ends with the same row/model readout.
            let bigRow: () -> Bool = { if let i = m.outlineIndex[big] { return table.selectedRow == i }; return false }
            func readout(_ tag: String) -> String { "\(tag): tableAtBig=\(bigRow()) tableRow=\(table.selectedRow) model=\(String(describing: m.selected)) coordinator[\(table.accessibilityHelp() ?? "nil")] \(SelDiag.summary)" }
            // DISPLAY-PROBE (not a product fix): force layout and display on the stuck state, then one real run-loop turn.
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); window.displayIfNeeded()
            let afterDisplay = bigRow()
            selDiag += " | " + readout("probe-display-immediate(\(afterDisplay))")
            try? await Task.sleep(nanoseconds: 100_000_000)
            selDiag += " | " + readout("probe-after-runloop-turn")
            // BISECT A: two model changes in one turn, no table change (nil then big).
            m.selected = nil; m.selected = big
            try? await Task.sleep(nanoseconds: 300_000_000)
            selDiag += " | " + readout("probe-A-two-model-changes-same-turn")
            // BISECT B: the same two changes separated by a real turn.
            m.selected = nil
            try? await Task.sleep(nanoseconds: 100_000_000)
            m.selected = big
            try? await Task.sleep(nanoseconds: 300_000_000)
            selDiag += " | " + readout("probe-B-two-model-changes-separate-turns")
        }
        let v0 = m.tree?.version ?? 0
        m.pendingRemoval = big; m.confirmRemoval()
        let accepted: Bool = m.removalInFlight
        let settled = await PublicationRegression.wait { !m.removalInFlight && m.commitsInFlight == 0 && (m.tree?.version ?? 0) > v0 && !m.rowsPending && table.numberOfRows == m.outlineRows.count }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let l1 = labels(table)
        snapshot(host, "outline-after-removal.png")
        let gone: Bool = !hasLabel(l1, "big.bin")
        let others: Bool = ["mid.bin", "small.bin", "tiny.bin"].allSatisfy { hasLabel(l1, $0) }
        let selClear: Bool = m.selected != big && (table.selectedRow < 0 || table.selectedRow >= l1.count || !l1[table.selectedRow].hasPrefix("big.bin,"))
        Check.expect("view-outline-removal-drops-row-and-clears-selection", selectedBeforeRemoval && accepted && settled && gone && others && selClear, "selectedBeforeRemoval=\(selectedBeforeRemoval) [\(selDiag)] accepted=\(accepted) settled=\(settled) bigRowGone=\(gone) othersPresent=\(others) selection=\(String(describing: m.selected)) selectedRow=\(table.selectedRow) labels=\(l1)")

        // Slice 3: poison in the mounted outline. A moved panic counter must replace every realized row's name and path with
        // "Unavailable" in the actual table (not just in the model), and the out-of-date state must be set.
        // Detector positive control on the UNPOISONED mounted table: the same reader must see a size text, share bars and a chevron
        // (the "sub" folder row) here, otherwise "none visible" after poison would prove nothing.
        let pre = visibleCellState(table)
        let preSize: Bool = pre.texts.contains { $0.contains("KB") || $0.contains("MB") || $0.contains("bytes") || $0.contains("byte") }
        let preControl: Bool = preSize && pre.barsVisible > 0 && pre.chevronsVisible > 0 && hasLabel(l1, "sub")
        let poisonAX = "Unavailable, engine error, rescan needed"
        var fake = m.panicBaseline
        m.panicCounter = { fake }
        fake += 1
        m.markPoisoned()
        let repainted = await PublicationRegression.wait { labels(table).allSatisfy { $0 == poisonAX } && table.numberOfRows > 0 }
        let l2 = labels(table)
        snapshot(host, "outline-poisoned.png")
        let noStaleName: Bool = !l2.contains { $0.contains(".bin") }
        let vis = visibleCellState(table)
        let noStaleNumbers: Bool = !vis.texts.contains { $0.contains("KB") || $0.contains("MB") || $0.contains("bytes") || $0.contains("byte") || $0.contains("item") }
        let noBarsOrChevrons: Bool = vis.barsVisible == 0 && vis.chevronsVisible == 0
        let flagged: Bool = m.viewOutOfDate && m.poisoned
        Check.expect("view-poison-outline-cells-show-unavailable-not-stale-names", preControl && repainted && noStaleName && noStaleNumbers && noBarsOrChevrons && flagged, "positiveControl=\(preControl) (sizeText=\(preSize) bars=\(pre.barsVisible) chevrons=\(pre.chevronsVisible)) repainted=\(repainted) noStaleName=\(noStaleName) noStaleNumbers=\(noStaleNumbers) noBarsOrChevrons=\(noBarsOrChevrons) visibleTexts=\(vis.texts) bars=\(vis.barsVisible) chevrons=\(vis.chevronsVisible) outOfDate=\(m.viewOutOfDate) poisoned=\(m.poisoned) labels=\(l2)")
        fake = m.panicBaseline   // counter returns to baseline: the latch must hold in the mounted table too
        try? await Task.sleep(nanoseconds: 300_000_000)
        let latchedView: Bool = labels(table).allSatisfy { $0 == poisonAX } && m.enginePoisoned
        Check.expect("view-poison-outline-latch-persists-in-mounted-table", latchedView, "latched=\(m.enginePoisoned) labels=\(labels(table))")
    }

    /// Filtered + expanded slice. V = read from the mounted NSTableView (labels, visible chevrons). M = model readouts (kindRows, largestIDs): the
    /// Kinds and Largest panes are NOT mounted here. Poison is not part of this fixture and is not covered by it.
    private static func folderLabel(_ l: [String], _ name: String) -> String? { l.first { $0.hasPrefix(name + ", folder") } }
    static func runFiltered() async {
        let dir = fixture("mounted-outline-filtered", [("big.txt", 600_000), ("keep.log", 70_000)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sub.appendingPathComponent("gone.txt").path, contents: Data(repeating: 7, count: 120_000))
        FileManager.default.createFile(atPath: sub.appendingPathComponent("stay.txt").path, contents: Data(repeating: 7, count: 60_000))
        FileManager.default.createFile(atPath: sub.appendingPathComponent("hidden.log").path, contents: Data(repeating: 7, count: 30_000))
        let m = AppModel(); m.scan(dir.path)
        guard await PublicationRegression.ready(m) != nil, let tree = m.tree, let gone = node(tree, "gone.txt"), let sdir = node(tree, "sub") else {
            Check.expect("view-outline-filtered-expanded-removal-readouts-coherent", false, "fixture: model never ready"); Check.expect("view-outline-filtered-expanded-selection-and-neighbors", false, "fixture: model never ready"); return
        }
        m.trashItem = { $0 }
        m.tab = .kinds
        m.filterExt = "txt"
        let filterOn: Bool = await PublicationRegression.wait { m.activeFilter != nil }
        let filterReady: Bool = await PublicationRegression.ready(m) != nil
        m.expanded = [sdir]; m.refreshOutline()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 520, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "CI mounted outline filtered+expanded (ordering driver)"
        let host = NSHostingView(rootView: OutlineView().environment(m))
        window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let mounted: Bool = await PublicationRegression.wait {
            if let t = findTable(host) { return t.numberOfRows > 0 && t.numberOfRows == m.outlineRows.count && hasLabel(labels(t), "gone.txt") }
            return false
        }
        guard filterOn, filterReady, mounted, let table = findTable(host) else {
            let why = "setup: filterOn=\(filterOn) filterReady=\(filterReady) mounted=\(mounted)"
            Check.expect("view-outline-filtered-expanded-removal-readouts-coherent", false, why); Check.expect("view-outline-filtered-expanded-selection-and-neighbors", false, why); return
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let l0 = labels(table)
        let v0state = visibleCellState(table)
        snapshot(host, "outline-filtered-before-removal.png")
        let stay = node(tree, "stay.txt"), bigID = node(tree, "big.txt")
        let before = (sub: folderLabel(l0, "sub"), texts: v0state.texts, chevrons: v0state.chevronsVisible, kindItems: m.kindRows.reduce(UInt64(0)) { $0 + $1.items },
                      largestHas: m.largestIDs.contains(gone), largestSurvivors: stay.map { m.largestIDs.contains($0) } == true && bigID.map { m.largestIDs.contains($0) } == true,
                      derivedCurrent: m.derivedVersion == m.tree?.version)
        // Positive controls: the filter is really applied in the view and the folder is really expanded.
        let controls: Bool = hasLabel(l0, "gone.txt") && hasLabel(l0, "stay.txt") && hasLabel(l0, "big.txt") && !hasLabel(l0, "keep.log") && !hasLabel(l0, "hidden.log")
            && before.sub == "sub, folder, 184 KB, 2 of 3 items match filter" && before.texts.contains("2 of 3 items") && before.chevrons >= 1 && before.largestHas && before.largestSurvivors && before.derivedCurrent && before.kindItems == 3

        m.selected = gone
        let selectedBefore: Bool = await PublicationRegression.wait { if let i = m.outlineIndex[gone] { return table.selectedRow == i }; return false }
        let v0 = m.tree?.version ?? 0
        m.pendingRemoval = gone; m.confirmRemoval()
        let accepted: Bool = m.removalInFlight
        let settled: Bool = await PublicationRegression.wait { !m.removalInFlight && m.commitsInFlight == 0 && (m.tree?.version ?? 0) > v0 && !m.rowsPending && table.numberOfRows == m.outlineRows.count }
        let derivedAfter: Bool = await PublicationRegression.wait { m.derivedVersion == m.tree?.version && !m.filterPending }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let l1 = labels(table)
        let v1state = visibleCellState(table)
        snapshot(host, "outline-filtered-after-removal.png")
        let after = (sub: folderLabel(l1, "sub"), texts: v1state.texts, chevrons: v1state.chevronsVisible, kindItems: m.kindRows.reduce(UInt64(0)) { $0 + $1.items },
                     largestHas: m.largestIDs.contains(gone), largestSurvivors: stay.map { m.largestIDs.contains($0) } == true && bigID.map { m.largestIDs.contains($0) } == true,
                     derivedCurrent: derivedAfter)
        let goneRowGone: Bool = !hasLabel(l1, "gone.txt")
        // "V of T items": V = visible direct children under the filter, T = structural live children (hidden.log is the third). Exact AX and visible text.
        let countDropped: Bool = after.sub == "sub, folder, 61 KB, 1 of 2 items match filter" && after.texts.contains("1 of 2 items") && !after.texts.contains("2 of 3 items")
        let kindsDropped: Bool = before.kindItems == 3 && after.kindItems == 2   // filtered Kinds total, a separate readout
        let largestOK: Bool = after.derivedCurrent && after.largestSurvivors && !after.largestHas
        let viewV = "V[rowGone=\(goneRowGone) subAX=\(String(describing: before.sub))->\(String(describing: after.sub)) visibleTexts=\(before.texts.filter { $0.contains("item") })->\(after.texts.filter { $0.contains("item") }) chevrons=\(before.chevrons)->\(after.chevrons) labels=\(l1)]"
        let modelM = "M[filteredKindItems=\(before.kindItems)->\(after.kindItems) largestHadGone=\(before.largestHas)->\(after.largestHas) largestSurvivorsBigStay=\(before.largestSurvivors)->\(after.largestSurvivors) derivedCurrent=\(after.derivedCurrent)] (Kinds/Largest panes not mounted)"
        Check.expect("view-outline-filtered-expanded-removal-readouts-coherent", controls && accepted && settled && goneRowGone && countDropped && after.chevrons >= 1 && kindsDropped && largestOK,
                     "controls=\(controls) accepted=\(accepted) settled=\(settled) \(viewV) \(modelM) l0=\(l0)")
        let neighbors: Bool = hasLabel(l1, "stay.txt") && hasLabel(l1, "big.txt") && hasLabel(l1, "sub")
        Check.expect("view-outline-filtered-expanded-selection-and-neighbors", selectedBefore && accepted && settled && m.selected == nil && table.selectedRow == -1 && neighbors && m.expanded.contains(sdir),
                     "selectedBefore=\(selectedBefore) modelSelected=\(String(describing: m.selected)) selectedRow=\(table.selectedRow) neighbors=\(neighbors) expandedKept=\(m.expanded.contains(sdir)) (asserted; no poison in this fixture)")
    }

    /// "V of T items" false pair and last-match semantics in the mounted outline. zf: a 0-byte match and a 0-byte non-match (filtered size == structural size,
    /// so a size heuristic cannot tell it is filtered). all: every child matches (plain "2 items"). lone: no matching descendant (no row at all).
    static func runFilteredCounts() async {
        let dir = fixture("mounted-outline-counts", [("top.txt", 100_000)])
        defer { try? FileManager.default.removeItem(at: dir) }
        func make(_ rel: String, _ bytes: Int) {
            let u = dir.appendingPathComponent(rel)
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: u.path, contents: Data(repeating: 7, count: bytes))
        }
        make("zf/m.txt", 0); make("zf/n.log", 0); make("all/p.txt", 10_000); make("all/q.txt", 10_000); make("lone/r.log", 5_000)
        let m = AppModel(); m.scan(dir.path)
        guard await PublicationRegression.ready(m) != nil, let tree = m.tree, let zf = node(tree, "zf"), let mfile = node(tree, "m.txt") else {
            Check.expect("view-outline-filtered-count-v-of-t-false-pair-and-all-match", false, "fixture: model never ready"); Check.expect("view-outline-last-match-removal-hides-folder", false, "fixture: model never ready"); return
        }
        m.trashItem = { $0 }
        m.tab = .kinds
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 520, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "CI mounted outline counts (ordering driver)"
        let host = NSHostingView(rootView: OutlineView().environment(m))
        window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let mounted: Bool = await PublicationRegression.wait { if let t = findTable(host) { return t.numberOfRows > 0 && t.numberOfRows == m.outlineRows.count && hasLabel(labels(t), "lone") }; return false }
        guard mounted, let table = findTable(host) else {
            Check.expect("view-outline-filtered-count-v-of-t-false-pair-and-all-match", false, "never mounted unfiltered"); Check.expect("view-outline-last-match-removal-hides-folder", false, "never mounted unfiltered"); return
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let lU = labels(table)
        let unfilteredOK: Bool = (folderLabel(lU, "zf")?.hasSuffix(", 2 items") ?? false) && (folderLabel(lU, "all")?.hasSuffix(", 2 items") ?? false) && hasLabel(lU, "lone")
        m.filterExt = "txt"
        let on: Bool = await PublicationRegression.wait { m.activeFilter != nil }
        let ready: Bool = await PublicationRegression.ready(m) != nil
        m.expanded = [zf]; m.refreshOutline()
        let shown: Bool = await PublicationRegression.wait { if let t = findTable(host) { return t.numberOfRows == m.outlineRows.count && hasLabel(labels(t), "m.txt") }; return false }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let lF = labels(table)
        let tF = visibleCellState(table).texts
        snapshot(host, "outline-counts-filtered.png")
        let zfL = folderLabel(lF, "zf"), allL = folderLabel(lF, "all")
        let zfOK: Bool = (zfL?.hasSuffix(", 1 of 2 items match filter") ?? false) && tF.contains("1 of 2 items")
        let allOK: Bool = (allL?.hasSuffix(", 2 items") ?? false) && !(allL?.contains("match filter") ?? true) && tF.contains("2 items")
        let loneHidden: Bool = !hasLabel(lF, "lone")
        Check.expect("view-outline-filtered-count-v-of-t-false-pair-and-all-match", unfilteredOK && on && ready && shown && zfOK && allOK && loneHidden,
                     "unfilteredOK=\(unfilteredOK) zfAX=\(String(describing: zfL)) allAX=\(String(describing: allL)) loneHidden=\(loneHidden) texts=\(tF.filter { $0.contains("item") }) labels=\(lF)")
        // Last match: removing the only matching descendant removes the folder row from the filtered outline (existing hide-by-match-count rule).
        m.selected = mfile
        let v0 = m.tree?.version ?? 0
        m.pendingRemoval = mfile; m.confirmRemoval()
        let accepted: Bool = m.removalInFlight
        let settled: Bool = await PublicationRegression.wait { !m.removalInFlight && m.commitsInFlight == 0 && (m.tree?.version ?? 0) > v0 && !m.rowsPending && table.numberOfRows == m.outlineRows.count }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let lA = labels(table)
        snapshot(host, "outline-counts-after-last-match.png")
        Check.expect("view-outline-last-match-removal-hides-folder", accepted && settled && !hasLabel(lA, "zf") && !hasLabel(lA, "m.txt") && hasLabel(lA, "all") && hasLabel(lA, "top.txt"),
                     "accepted=\(accepted) settled=\(settled) zfRowGone=\(!hasLabel(lA, "zf")) labels=\(lA)")
    }
}

/// Isolated native API guards, not actual keyboard-shortcut or IME proof.
/// ACTUAL-VIEW and ACTUAL-ENGINE slice (test binary only). The treemap below is the production TreemapView mounted in a
/// real NSWindow: the layout gate is released by the VIEW (no layoutPublished call from this test). The Trash is still
/// mocked and the outline view is not mounted here. Pixels are real bitmaps of the hosted window, written as PNGs next to
/// assertions.txt and judged by pixel difference, not by model state alone.
@MainActor private enum MountedViewRegression {
    private static func fixture(_ tag: String, _ files: [(String, Int)]) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spz-\(tag)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (n, k) in files { FileManager.default.createFile(atPath: root.appendingPathComponent(n).path, contents: Data(repeating: 7, count: k)) }
        return root
    }
    private static func node(_ t: Tree, _ name: String) -> UInt32? { (0..<UInt32(t.nodeCount)).first { t.name($0) == name } }
    private static func snapshot(_ view: NSView, _ file: String) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let dir = (Check.path as NSString).deletingLastPathComponent
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: dir + "/" + file)) }
        return rep
    }
    /// (pixels that differ, total pixels, distinct colors in `a`), or nil when the bitmaps are not comparable.
    private static func compare(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (differing: Int, total: Int, distinct: Int, distinctAfter: Int)? {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.samplesPerPixel == b.samplesPerPixel, a.bitsPerSample == 8,
              let pa = a.bitmapData, let pb = b.bitmapData else { return nil }
        let spp = a.samplesPerPixel
        var diff = 0, colors = Set<UInt32>(), colorsB = Set<UInt32>()
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                let ia = y * a.bytesPerRow + x * spp, ib = y * b.bytesPerRow + x * spp
                var same = true, key: UInt32 = 0, keyB: UInt32 = 0
                for c in 0..<min(spp, 3) {
                    if abs(Int(pa[ia + c]) - Int(pb[ib + c])) > 2 { same = false }
                    key = key << 8 | UInt32(pa[ia + c]); keyB = keyB << 8 | UInt32(pb[ib + c])
                }
                if !same { diff += 1 }
                colors.insert(key); colorsB.insert(keyB)
            }
        }
        return (diff, a.pixelsWide * a.pixelsHigh, colors.count, colorsB.count)
    }

    static func run() async {
        await treemap()
        await engine()
    }

    private static func treemap() async {
        let dir = fixture("mounted-view", [("big.bin", 600_000), ("mid.bin", 250_000), ("small.bin", 90_000), ("tiny.bin", 40_000)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = AppModel(); m.scan(dir.path)
        guard await PublicationRegression.ready(m) != nil, let tree = m.tree, let big = node(tree, "big.bin") else {
            Check.expect("view-treemap-layout-gate-released-by-real-view", false, "fixture: model never ready"); Check.expect("view-treemap-pixels-change-after-removal", false, "fixture: model never ready"); return
        }
        m.trashItem = { $0 }   // mocked Trash seam: nothing is moved on disk
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 520, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "CI mounted treemap (ordering driver)"
        let host = NSHostingView(rootView: TreemapView().environment(m))
        window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        // The real view publishes the first layout by itself.
        let first = await PublicationRegression.wait { m.layoutVersion != nil && m.layoutVersion == m.tree?.version && !m.rowsPending }
        try? await Task.sleep(nanoseconds: 700_000_000)   // let the Canvas draw before taking pixels
        let before = snapshot(host, "treemap-before-removal.png")
        let v0 = m.tree?.version ?? 0
        m.pendingRemoval = big; m.confirmRemoval()
        let accepted = m.removalInFlight
        var sawRequired = false
        let settled = await PublicationRegression.wait {
            if m.requiredVersion != nil { sawRequired = true }
            return !m.removalInFlight && m.commitsInFlight == 0 && (m.tree?.version ?? 0) > v0 && !m.rowsPending
        }
        let vNow = m.tree?.version ?? 0
        let versionAdvanced: Bool = vNow > v0
        let gateReleased: Bool = m.requiredVersion == nil && !m.navigationBlocked
        let layoutCurrent: Bool = m.layoutVersion == m.tree?.version
        let gateOK: Bool = first && accepted && settled && versionAdvanced && gateReleased && layoutCurrent
        Check.expect("view-treemap-layout-gate-released-by-real-view", gateOK,
                     "initialLayoutByView=\(first) accepted=\(accepted) settled=\(settled) version \(v0)->\(vNow) layoutVersion=\(String(describing: m.layoutVersion)) required=\(String(describing: m.requiredVersion)) sawRequiredWhileSampling=\(sawRequired) (no layoutPublished call from the test; Trash mocked)")
        try? await Task.sleep(nanoseconds: 700_000_000)
        let after = snapshot(host, "treemap-after-removal.png")
        if let before, let after, let c = compare(before, after) {
            // The largest block is gone, so a large share of pixels must change; neither picture may be blank (>= 3 distinct colors).
            let notBlank: Bool = c.distinct >= 3 && c.distinctAfter >= 3
            let changed: Bool = c.differing * 20 > c.total
            Check.expect("view-treemap-pixels-change-after-removal", notBlank && changed, "differing=\(c.differing) of \(c.total) pixels, distinctColorsBefore=\(c.distinct) distinctColorsAfter=\(c.distinctAfter), PNGs treemap-before-removal.png / treemap-after-removal.png")
        } else { Check.expect("view-treemap-pixels-change-after-removal", false, "snapshot unavailable or bitmaps not comparable") }
    }

    /// A parked read that a test can release. Sendable by lock, not by actor, so a test can open it from the main actor.
    private final class ReviewGate: @unchecked Sendable {
        private let lock = NSLock(); private var opened = false
        /// Bounded: returns when opened or after about 5 s, whichever is first. A gate nobody opens makes the check FAIL, never hang the run.
        func wait() async {
            for _ in 0..<500 where !isOpen { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        func open() { lock.lock(); opened = true; lock.unlock() }
        var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return opened }
    }
    private static func settle(_ cond: () -> Bool) async { for _ in 0..<300 where !cond() { try? await Task.sleep(nanoseconds: 10_000_000) } }

    /// UNCOMPILED/UNRUN until a Mac run. Deterministic: every step that must happen after another waits on a gate, not on a sleep.
    private static func reviewModelChecks() async {
        let names = ["review-model-version-change-drops-result-and-clears-progress", "review-model-newer-request-wins-and-late-result-is-ignored", "review-cancel-reaches-the-inner-read-and-clears-state"]
        let d = fixture("review-model", [("a.bin", 30_000), ("b.bin", 20_000), ("c.bin", 10_000)])
        defer { try? FileManager.default.removeItem(at: d) }
        guard let t = await ScanSession(root: d.path, excludes: [])?.run({ _ in }), let a = node(t, "a.bin"), let b = node(t, "b.bin"), let c = node(t, "c.bin") else {
            for n in names { Check.expect(n, false, "fixture") }; return
        }

        // 1. The table version moves while the read is parked: the late answer is dropped, progress ends, outdated is set.
        let g1 = ReviewGate()
        let m1 = ItemReviewModel(reviewer: { tree, id, v in await g1.wait(); return reviewTestAnswer(tree, id, v) })
        m1.request(tree: t, node: b)
        let inFlightBefore = m1.inProgress
        _ = t.forget(c)                       // real engine mutation on this tree: version advances
        g1.open()
        let tok1 = m1.token
        await settle { m1.processedTokens.contains(tok1) }
        Check.expect("review-model-version-change-drops-result-and-clears-progress", inFlightBefore && m1.processedTokens.contains(tok1) && m1.result == nil && !m1.inProgress && m1.outdated, "inFlightBefore=\(inFlightBefore) result=\(String(describing: m1.result)) inProgress=\(m1.inProgress) outdated=\(m1.outdated)")

        // 2. A newer request wins; the older answer arriving later changes nothing. Waits are on the model's own "answer processed" signal (test builds only).
        // This is token/staleness logic only: it does NOT prove cancellation reached anything (check 3 covers that for the real review).
        let gA = ReviewGate(), gB = ReviewGate()
        let m2 = ItemReviewModel(reviewer: { tree, id, v in if id == a { await gA.wait() } else { await gB.wait() }; return reviewTestAnswer(tree, id, v) })
        m2.request(tree: t, node: a); let tokA = m2.token
        m2.request(tree: t, node: b); let tokB = m2.token
        gB.open()
        await settle { m2.processedTokens.contains(tokB) }
        let shownB = m2.result?.node == b && !m2.inProgress
        gA.open()
        await settle { m2.processedTokens.contains(tokA) }          // the late answer has now been through the acceptance logic
        Check.expect("review-model-newer-request-wins-and-late-result-is-ignored", tokA != tokB && m2.processedTokens.contains(tokA) && shownB && m2.result?.node == b && !m2.inProgress && !m2.outdated, "tokA=\(tokA) tokB=\(tokB) processed=\(m2.processedTokens.sorted()) shownB=\(shownB) result=\(m2.result.map { String($0.node) } ?? "nil") inProgress=\(m2.inProgress) outdated=\(m2.outdated)")

        // 3. Cancelling the caller of the REAL review reaches the inner detached read (a plain detached task would not see it).
        // The park hook signals when the inner task is parked, and records whether it saw the cancellation. This says nothing about
        // interrupting an FFI call: cancellation is only observed between steps. Then invalidate() on the model, waiting for the late answer.
        let entered = ReviewGate(), sawCancel = ReviewGate()
        let real = Task { try await ItemReview.review(tree: t, id: a, version: t.version, parkForTest: {
            entered.open()
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { sawCancel.open(); throw error }
        }) }
        await entered.wait()                          // bounded (5 s): the inner read is parked, so the handler is genuinely exercised
        let enteredOK = entered.isOpen
        real.cancel()
        let outcome = await real.result
        let cancelled: Bool = { if case .failure(let e) = outcome { return e is CancellationError }; return false }()
        let g3 = ReviewGate()
        let m3 = ItemReviewModel(reviewer: { _, _, _ in await g3.wait(); throw CancellationError() })
        m3.request(tree: t, node: a); let tok3 = m3.token
        let inProgressBefore = m3.inProgress
        m3.invalidate()
        g3.open()
        await settle { m3.processedTokens.contains(tok3) }       // the late (cancelled) completion has been handled
        Check.expect("review-cancel-reaches-the-inner-read-and-clears-state", enteredOK && cancelled && sawCancel.isOpen && inProgressBefore && m3.processedTokens.contains(tok3) && m3.result == nil && !m3.inProgress && !m3.outdated, "cancelled=\(cancelled) innerSawCancel=\(sawCancel.isOpen) inProgressBefore=\(inProgressBefore) processed=\(m3.processedTokens.contains(tok3)) result=\(m3.result == nil ? "nil" : "set") inProgress=\(m3.inProgress) outdated=\(m3.outdated)")
    }

    private static func engine() async {
        let d1 = fixture("engine-old", [("f1.bin", 40_000), ("f2.bin", 24_000), ("f3.bin", 8_000)])
        let d2 = fixture("engine-new", [("g1.bin", 30_000), ("g2.bin", 10_000)])
        defer { try? FileManager.default.removeItem(at: d1); try? FileManager.default.removeItem(at: d2) }
        let scan1 = await ScanSession(root: d1.path, excludes: [])?.run { _ in }
        let scan2 = await ScanSession(root: d2.path, excludes: [])?.run { _ in }
        guard let t1 = scan1, let t2 = scan2,
              let f1 = node(t1, "f1.bin"), let f2 = node(t1, "f2.bin"), let f3 = node(t1, "f3.bin") else {
            Check.expect("engine-old-tree-forget-advances-old-only-after-swap", false, "fixture"); Check.expect("engine-concurrent-forgets-on-one-tree-no-lost-update", false, "fixture"); return
        }
        // ABI: the imported C struct must match Rust's layout exactly (size, alignment, field offsets), or a drift fails here loudly.
        var lay = [UInt64](repeating: 0, count: 5)
        lay.withUnsafeMutableBufferPointer { spz_row_info_layout($0.baseAddress) }
        let abiOK: Bool = lay[0] == UInt64(MemoryLayout<SpzRowInfo>.size) && lay[1] == UInt64(MemoryLayout<SpzRowInfo>.alignment)
            && lay[2] == UInt64(MemoryLayout<SpzRowInfo>.offset(of: \.node) ?? 9999) && lay[3] == UInt64(MemoryLayout<SpzRowInfo>.offset(of: \.shown) ?? 9999)
            && lay[4] == UInt64(MemoryLayout<SpzRowInfo>.offset(of: \.visible_children) ?? 9999)
        Check.expect("engine-row-info-abi-matches-rust", abiOK, "rust[size,align,node,shown,visible]=\(lay) swift[size=\(MemoryLayout<SpzRowInfo>.size) align=\(MemoryLayout<SpzRowInfo>.alignment) stride=\(MemoryLayout<SpzRowInfo>.stride) node=\(String(describing: MemoryLayout<SpzRowInfo>.offset(of: \.node))) shown=\(String(describing: MemoryLayout<SpzRowInfo>.offset(of: \.shown))) visible=\(String(describing: MemoryLayout<SpzRowInfo>.offset(of: \.visible_children)))]")
        // Inspect ABI (UNCOMPILED/UNRUN until a Mac run): the imported SpzInspect must match Rust's layout.
        var il = [UInt64](repeating: 0, count: 7)
        il.withUnsafeMutableBufferPointer { spz_inspect_layout($0.baseAddress) }
        let inspOK: Bool = il[0] == UInt64(MemoryLayout<SpzInspect>.size) && il[1] == UInt64(MemoryLayout<SpzInspect>.alignment)
            && il[2] == UInt64(MemoryLayout<SpzInspect>.offset(of: \.mtime) ?? 9999) && il[3] == UInt64(MemoryLayout<SpzInspect>.offset(of: \.dev) ?? 9999)
            && il[4] == UInt64(MemoryLayout<SpzInspect>.offset(of: \.ino) ?? 9999) && il[5] == UInt64(MemoryLayout<SpzInspect>.offset(of: \.nlink) ?? 9999)
            && il[6] == UInt64(MemoryLayout<SpzInspect>.offset(of: \.kind) ?? 9999)
        Check.expect("engine-inspect-abi-matches-rust", inspOK, "rust[size,align,mtime,dev,ino,nlink,kind]=\(il) swift[size=\(MemoryLayout<SpzInspect>.size) align=\(MemoryLayout<SpzInspect>.alignment)]")
        // Same real files, three views: the scanner's recorded identity (macOS bulk backend), the engine's live lstat, and Foundation's own lstat.
        // Every item must read Same, and the independent lstat must agree with the engine's on ino, 32-bit dev and logical size.
        var identOK = true; var identDetail = ""
        for id in [UInt32(0), f1, f2, f3] {
            let code = spz_tree_check_identity(t1.ptr, id)
            var insp = SpzInspect(); let rc = spz_inspect_path(t1.path(id), &insp)
            var lst = stat(); let lrc = lstat(t1.path(id), &lst)
            let agree = rc == 0 && lrc == 0 && UInt64(lst.st_ino) == insp.ino && UInt32(truncatingIfNeeded: lst.st_dev) == UInt32(truncatingIfNeeded: insp.dev) && (id == 0 || UInt64(lst.st_size) == insp.logical)
            if code != 0 || !agree { identOK = false; identDetail += " id=\(id) check=\(code) inspect=\(rc) lstat=\(lrc) ino=\(lst.st_ino)/\(insp.ino) dev=\(lst.st_dev)/\(insp.dev);" }
        }
        Check.expect("engine-scanned-identity-matches-lstat-on-fixture", identOK, identOK ? "root and 3 files Same; Foundation lstat agrees with engine lstat" : identDetail)
        await reviewModelChecks()
        // Real engine forget on the OLD tree handle after a second tree exists: only the old tree changes.
        let v1 = t1.version, v2 = t2.version, r1 = t1.info(0).size, r2 = t2.info(0).size, s1 = t1.info(f1).size, s2 = t1.info(f2).size, s3 = t1.info(f3).size
        let st = t1.forget(f1)
        let oldAdvanced: Bool = t1.version == v1 + 1
        let oldRootOK: Bool = t1.info(0).size == r1 - s1
        let oldNodeZero: Bool = t1.info(f1).size == 0
        let newUntouched: Bool = t2.version == v2 && t2.info(0).size == r2
        let oldKidsLive: Bool = t1.info(0).childCount == 2 && t2.info(0).childCount == 2   // removed child no longer counted; the other tree keeps its own
        let okSwap: Bool = st == .ok && oldAdvanced && oldRootOK && oldNodeZero && newUntouched && oldKidsLive
        Check.expect("engine-old-tree-forget-advances-old-only-after-swap", okSwap, "liveChildCount old=\(t1.info(0).childCount) new=\(t2.info(0).childCount) status=\(st) oldVersion \(v1)->\(t1.version) oldRoot \(r1)->\(t1.info(0).size) (forgot \(s1)) newTreeVersion \(v2)->\(t2.version) newTreeRoot \(r2)->\(t2.info(0).size)")
        // Two real forgets on two DISTINCT live files of one real tree, issued from two concurrent tasks. Bounded and small:
        // it shows neither update is lost (exact sum, version +2, both OK); it is not a stress test.
        let vA = t1.version, rA = t1.info(0).size
        async let a: EngineStatus = Task.detached { t1.forget(f2) }.value
        async let b: EngineStatus = Task.detached { t1.forget(f3) }.value
        let (sa, sb) = await (a, b)
        let nodesZero: Bool = t1.info(f2).size == 0 && t1.info(f3).size == 0
        let rootOK: Bool = t1.info(0).size == rA - s2 - s3
        let versionOK: Bool = t1.version == vA + 2
        let noKidsLeft: Bool = t1.info(0).childCount == 0
        let okDbl: Bool = sa == .ok && sb == .ok && nodesZero && rootOK && versionOK && noKidsLeft
        Check.expect("engine-concurrent-forgets-on-one-tree-no-lost-update", okDbl, "liveChildCount=\(t1.info(0).childCount) statuses \(sa)/\(sb) root \(rA)->\(t1.info(0).size) expected \(rA - s2 - s3) version \(vA)->\(t1.version) expected \(vA + 2)")
    }
}

@MainActor private enum BoundaryGuardRegression {
    private final class TableData: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 1 }
    }
    private final class RefusingField: NSTextField {
        override var acceptsFirstResponder: Bool { true }
        var becomeCalls = 0
        override func becomeFirstResponder() -> Bool { becomeCalls += 1; Perf.log("boundary-native target-become called=\(becomeCalls) result=false"); return false }
    }
    private final class BoundaryWindow: NSWindow {
        // NSTableView.dataSource is weak. Own it through the entire async fixture.
        var retainedTableData: TableData?
        weak var challengedTarget: NSResponder?
        weak var restoreSource: NSResponder?
        weak var decoy: NSResponder?
        var fakeRefusalWithLanding = false
        var fakeRestoreFailure = false
        var decoyLandingVerified = false
        var restoreRefusalObserved = false
        var traceNativeFocus = false
        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            if fakeRefusalWithLanding && responder === challengedTarget {
                let accepted = super.makeFirstResponder(decoy)
                decoyLandingVerified = accepted && (firstResponder === decoy || (firstResponder as? NSTextView)?.delegate === decoy) && firstResponder !== restoreSource
                Perf.log("boundary-sim decoyAccepted=\(accepted) decoyVerified=\(decoyLandingVerified) responder=\(String(describing: firstResponder))")
                return false
            }
            if fakeRestoreFailure && responder === restoreSource { restoreRefusalObserved = true; Perf.log("boundary-sim restore-refused"); return false }
            let before = firstResponder
            let accepted = super.makeFirstResponder(responder)
            if traceNativeFocus { Perf.log("boundary-native target=\(String(describing: responder)) accepted=\(accepted) before=\(String(describing: before)) after=\(String(describing: firstResponder))") }
            return accepted
        }
    }
    static let names = ["boundary-helper-missing-target", "boundary-helper-hidden-target", "boundary-helper-disabled-target", "boundary-helper-other-window", "boundary-helper-hidden-source", "boundary-helper-source-not-current", "boundary-helper-modified-tab-refused", "boundary-helper-focus-refusal", "boundary-helper-refusal-changed-restored", "boundary-helper-restore-failure-consumes", "boundary-helper-inactive-source-window"]
    static func recordMissing(_ reason: String) { for name in names { Check.expect(name, false, reason) } }
    static func run(restoring product: NSWindow) async {
        let model = AppModel()
        let window = BoundaryWindow(contentRect: NSRect(x: -1000, y: -1000, width: 180, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); product.makeKeyAndOrderFront(nil) }
        let source = NSTableView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
        let tableData = TableData()
        window.retainedTableData = tableData
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("boundary-source"))
        source.addTableColumn(column)
        source.dataSource = tableData
        source.headerView = nil
        source.allowsEmptySelection = true
        source.reloadData()
        let scroll = NSScrollView(frame: source.frame)
        scroll.documentView = source
        let target = NSTextField(frame: NSRect(x: 90, y: 0, width: 80, height: 24))
        window.contentView?.addSubview(scroll); window.contentView?.addSubview(target)
        model.outlineKeyView = source; model.nameFilterKeyView = target
        window.makeKeyAndOrderFront(nil)
        let initialResponderAccepted = window.makeFirstResponder(source)
        let setupDeadline = Date().addingTimeInterval(3)
        while (!window.isKeyWindow || !NSApp.isActive) && Date() < setupDeadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        let setup = initialResponderAccepted && source.acceptsFirstResponder && window.firstResponder === source && window.isKeyWindow && NSApp.isActive
        @MainActor func guardDiagnostic(_ name: String) -> String {
            "\(name) initialAccepted=\(initialResponderAccepted) setup=\(setup) sourceAccepts=\(source.acceptsFirstResponder) rows=\(source.numberOfRows) columns=\(source.numberOfColumns) sourceIdentity=\(window.firstResponder === source) key=\(window.isKeyWindow) active=\(NSApp.isActive) visible=\(window.isVisible) sourceVisible=\(!source.isHiddenOrHasHiddenAncestor) sourceEnabled=\(source.isEnabled) responder=\(String(describing: window.firstResponder)) target=\(String(describing: model.nameFilterKeyView))"
        }
        Perf.log("boundary-setup \(guardDiagnostic("initial"))")
        @MainActor func currentSource() -> Bool { window.isKeyWindow && NSApp.isActive && window.firstResponder === source }
        @MainActor func resetSource() -> Bool { window.makeFirstResponder(source) && currentSource() }
        @MainActor func refuses() -> Bool { model.focusNameFromOutline(source, modifiers: []) == .unavailable && window.firstResponder === source }
        @MainActor func guardCheck(_ name: String, _ condition: Bool, _ detail: String = "") {
            Check.expect(name, condition, "\(guardDiagnostic(name)) \(detail)")
        }
        model.nameFilterKeyView = nil
        guardCheck("boundary-helper-missing-target", setup && currentSource() && refuses())
        model.nameFilterKeyView = target; target.isHidden = true
        guardCheck("boundary-helper-hidden-target", setup && currentSource() && refuses()); target.isHidden = false
        target.isEnabled = false
        guardCheck("boundary-helper-disabled-target", setup && currentSource() && refuses()); target.isEnabled = true
        let foreign = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        foreign.isReleasedWhenClosed = false
        defer { foreign.close() }
        target.removeFromSuperview(); foreign.contentView?.addSubview(target)
        guardCheck("boundary-helper-other-window", setup && currentSource() && refuses())
        target.removeFromSuperview(); window.contentView?.addSubview(target)
        let beforeHiddenSource = currentSource()
        source.isHidden = true
        let afterHide = window.firstResponder
        Perf.log("boundary-hidden beforeSource=\(beforeHiddenSource) afterHide=\(String(describing: afterHide))")
        let hiddenResult = model.focusNameFromOutline(source, modifiers: [])
        // Hiding a native first responder may relocate it before the helper runs.
        // Assert the helper does not change that captured responder, not that AppKit kept a hidden table focused.
        guardCheck("boundary-helper-hidden-source", setup && beforeHiddenSource && source.isHiddenOrHasHiddenAncestor && hiddenResult == .unavailable && window.firstResponder === afterHide, "posthide identity preserved; hidden/not-current predicates may overlap")
        source.isHidden = false
        let unrelatedSetup = window.makeFirstResponder(target)
        let unrelated = window.firstResponder
        guardCheck("boundary-helper-source-not-current", setup && unrelatedSetup && unrelated !== source && model.focusNameFromOutline(source, modifiers: []) == .unavailable && window.firstResponder === unrelated)
        let modifierSetup = resetSource()
        let modified = [NSEvent.ModifierFlags.command, .control, .option, .shift].allSatisfy { model.focusNameFromOutline(source, modifiers: $0) == .unavailable && window.firstResponder === source }
        guardCheck("boundary-helper-modified-tab-refused", setup && modifierSetup && modified, "helper only, not actual shortcut handling")
        let refusal = RefusingField(frame: target.frame); window.contentView?.addSubview(refusal); model.nameFilterKeyView = refusal
        let refusalSetup = currentSource()
        window.traceNativeFocus = true
        let refusalResult = model.focusNameFromOutline(source, modifiers: [])
        window.traceNativeFocus = false
        // AppKit can return true with the window as responder when becomeFirstResponder refuses.
        let refusalSafelyRestored = refusalResult == .unavailable || refusalResult == .restoredUnexpectedLanding
        guardCheck("boundary-helper-focus-refusal", setup && refusalSetup && refusal.becomeCalls > 0 && refusalSafelyRestored && !refusalResult.consumesCommand && window.firstResponder === source, "result=\(refusalResult) targetBecomeCalls=\(refusal.becomeCalls) native target refusal+exact source preserved/restored; not caller fallback proof")
        let decoy = NSTextField(frame: NSRect(x: 0, y: 90, width: 70, height: 24)); window.contentView?.addSubview(decoy)
        model.nameFilterKeyView = target
        let restoreCaseSetup = resetSource()
        window.challengedTarget = target; window.restoreSource = source; window.decoy = decoy
        window.fakeRefusalWithLanding = true
        let restored = model.focusNameFromOutline(source, modifiers: [])
        guardCheck("boundary-helper-refusal-changed-restored", setup && restoreCaseSetup && window.decoyLandingVerified && restored == .restoredUnexpectedLanding && window.firstResponder === source, "simulated API false with changed landing")
        let failureCaseSetup = currentSource()
        window.decoyLandingVerified = false
        window.fakeRestoreFailure = true
        let failedRestore = model.focusNameFromOutline(source, modifiers: [])
        guardCheck("boundary-helper-restore-failure-consumes", setup && failureCaseSetup && window.decoyLandingVerified && window.restoreRefusalObserved && failedRestore == .restoreFailed && failedRestore.consumesCommand && (window.firstResponder === decoy || (window.firstResponder as? NSTextView)?.delegate === decoy), "simulated API refusal+restore failure")
        window.fakeRefusalWithLanding = false; window.fakeRestoreFailure = false
        let beforeInactive = resetSource()
        product.makeKeyAndOrderFront(nil)
        guardCheck("boundary-helper-inactive-source-window", setup && beforeInactive && !window.isKeyWindow && model.focusNameFromOutline(source, modifiers: []) == .unavailable && window.firstResponder === source)
        window.close(); foreign.close(); product.makeKeyAndOrderFront(nil)
    }
}

/// CI-only: read the real hosted native accessibility descendants, never substitute the authored SwiftUI label.
@MainActor private enum FooterAXEvidence {
    struct Entry { let label: String; let help: String }
    struct Result { let entries: [Entry]; let truncated: Bool }
    static func inspect(_ root: NSWindow) -> Result {
        var entries: [Entry] = []
        var seen = Set<ObjectIdentifier>()
        var truncated = false
        var discovered = 0, rejected = 0
        func visit(_ object: Any, depth: Int, edge: String) {
            guard depth < 24, discovered < 512 else { truncated = true; return }
            guard let instance = object as? NSObject else {
                discovered += 1; rejected += 1
                Perf.log("footer-ax discovery edge=\(edge) depth=\(depth) class=\(String(reflecting: type(of: object))) unsupported-nonNSObject")
                return
            }
            guard seen.insert(ObjectIdentifier(instance)).inserted else { return }
            discovered += 1
            let protocolNode = instance as? NSAccessibilityProtocol
            let view = instance as? NSView
            let window = instance as? NSWindow
            let label: String?, help: String?, children: [Any]
            // Typed AppKit methods are supported even when protocol discovery is rejected.
            // Hierarchy discovery does not depend on a successful accessibility protocol cast.
            if let view {
                label = view.accessibilityLabel(); help = view.accessibilityHelp()
                children = view.accessibilityChildren() ?? []
            } else if let window {
                label = window.accessibilityLabel(); help = window.accessibilityHelp()
                children = window.accessibilityChildren() ?? []
            } else if let protocolNode {
                label = protocolNode.accessibilityLabel(); help = protocolNode.accessibilityHelp()
                children = protocolNode.accessibilityChildren() ?? []
            } else {
                label = nil; help = nil; children = []; rejected += 1
            }
            Perf.log("footer-ax discovery edge=\(edge) depth=\(depth) class=\(NSStringFromClass(type(of: instance))) protocol=\(protocolNode != nil) view=\(view != nil) window=\(window != nil) readable=\(view != nil || window != nil || protocolNode != nil)")
            if view != nil || window != nil || protocolNode != nil {
                entries.append(Entry(label: label ?? "", help: help ?? ""))
                Perf.log("footer-ax edge=\(edge) depth=\(depth) label=\((label ?? "").debugDescription) help=\((help ?? "").debugDescription)")
            }
            let views = view?.subviews ?? []
            let content = window?.contentView.map { [$0] } ?? []
            for (childEdge, descendants) in [("ax-child", children), ("view-subview", views as [Any]), ("window-content", content as [Any])] {
                for child in descendants {
                    if discovered >= 512 { truncated = true; break }
                    visit(child, depth: depth + 1, edge: childEdge)
                }
                if discovered >= 512 { break }
            }
        }
        visit(root, depth: 0, edge: "root-window")
        Perf.log("footer-ax complete nodes=\(entries.count) discovered=\(discovered) rejectedBranches=\(rejected) truncated=\(truncated); rejected non-view/nonprotocol branches remain uninspected, no authored substitution")
        return Result(entries: entries, truncated: truncated)
    }

}

@MainActor private enum TreemapMountedRegression {
    final class Results {
        var values: [(token: UUID, generation: UInt64, requestedSize: CGSize, requestedTreeID: ObjectIdentifier, requestedFilterID: ObjectIdentifier?, accepted: Bool, evidence: TreemapPublicationEvidence)] = []
    }
    static func run(capture: (Int) -> Void) async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spz-mounted-treemap-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try? Data(repeating: 65, count: 32768).write(to: directory.appendingPathComponent("large.txt"))
        try? Data(repeating: 66, count: 16384).write(to: directory.appendingPathComponent("small.bin"))
        let tree = await ScanSession(root: directory.path, excludes: [])?.run { _ in }
        let model = AppModel(); model.tree = tree
        let prior = DemoInput.window
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 520, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "CI actual mounted treemap publication"
        let barrier = PublicationBarrier("treemap"), results = Results(), probe = TreemapPublicationProbe()
        probe.before = { token, generation, requestedSize, requestedTreeID, requestedFilterID in
            if requestedSize == CGSize(width: 520, height: 300) { await barrier.before("treemap", generation, token) }
        }
        probe.after = { token, generation, requestedSize, requestedTreeID, requestedFilterID, accepted, evidence in
            results.values.append((token, generation, requestedSize, requestedTreeID, requestedFilterID, accepted, evidence))
            Task { await barrier.after("treemap", generation, token) }
            Perf.log("treemap-mounted token=\(token) generation=\(generation) requestedSize=\(requestedSize) requestedTreeID=\(requestedTreeID) requestedFilterID=\(String(describing: requestedFilterID)) accepted=\(accepted) layout=\(String(describing: evidence.layoutID)) tree=\(String(describing: evidence.treeID)) publishedFilterID=\(String(describing: evidence.filterID)) size=\(evidence.size) hitValid=\(evidence.hitValid)")
        }
        let host = NSHostingView(rootView: TreemapView(publicationProbe: probe).environment(model))
        window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
        defer { probe.before = nil; probe.after = nil; probe.readEvidence = nil; window.close(); prior?.makeKeyAndOrderFront(nil) }
        let parked = await PublicationRegression.wait { await barrier.parked() }
        guard parked else {
            await barrier.release()
            Check.expect("treemap-mounted-newer-resize-published", false, "520x300 request did not park; inconclusive lifecycle fixture")
            return
        }
        let oldToken = await barrier.heldToken()
        window.setContentSize(NSSize(width: 680, height: 360))
        func validNew(_ value: (token: UUID, generation: UInt64, requestedSize: CGSize, requestedTreeID: ObjectIdentifier, requestedFilterID: ObjectIdentifier?, accepted: Bool, evidence: TreemapPublicationEvidence)) -> Bool {
            value.accepted && value.requestedSize == CGSize(width: 680, height: 360) && value.evidence.size == value.requestedSize && value.evidence.treeID == tree.map(ObjectIdentifier.init) && value.evidence.layoutID != nil && value.evidence.hitValid
        }
        let newer = await PublicationRegression.wait { results.values.contains(where: validNew) }
        try? await Task.sleep(nanoseconds: 700_000_000) // yield for Canvas rendering; pixels remain decisive
        let newState = results.values.last(where: validNew)
        let beforeCapture = probe.readEvidence?()
        let stillHeld = !(await barrier.completed())
        Check.expect("treemap-mounted-newer-resize-published", tree != nil && newer && stillHeld && window.isVisible && host.window === window && beforeCapture?.layoutID == newState?.evidence.layoutID && beforeCapture?.hitValid == true, "actual Rust layout + hosted view; pixels41 required")
        guard newer, stillHeld, let newState else { await barrier.release(); return }
        capture(41)
        await barrier.release()
        let attempted = await PublicationRegression.wait { await barrier.completed() }
        try? await Task.sleep(nanoseconds: 700_000_000) // allow rendered state to settle before42
        let old = results.values.last { $0.token == oldToken && !$0.accepted }
        let afterCapture = probe.readEvidence?()
        Check.expect("treemap-mounted-old-resize-rejected-preserves-hit", attempted && old?.requestedSize == CGSize(width: 520, height: 300) && (old?.generation ?? UInt64.max) < newState.generation && old?.evidence.layoutID == newState.evidence.layoutID && old?.evidence.treeID == newState.evidence.treeID && old?.evidence.size == newState.evidence.size && old?.evidence.hitValid == true && afterCapture?.layoutID == newState.evidence.layoutID && afterCapture?.treeID == newState.evidence.treeID && afterCapture?.size == newState.evidence.size && afterCapture?.hitValid == true, "token-specific old callback ran; actual currentLayout/hit path; pixels42 required")
        capture(42)
    }
}

@MainActor private enum TreemapMountedTreeSwapRegression {
    final class Results {
        var values: [(token: UUID, generation: UInt64, requestedSize: CGSize, requestedTreeID: ObjectIdentifier, requestedFilterID: ObjectIdentifier?, accepted: Bool, evidence: TreemapPublicationEvidence)] = []
    }
    static func run(capture: (Int) -> Void) async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spz-mounted-tree-swap-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try? Data(repeating: 65, count: 32768).write(to: directory.appendingPathComponent("old-large.txt"))
        try? Data(repeating: 66, count: 16384).write(to: directory.appendingPathComponent("old-small.bin"))
        let tree = await ScanSession(root: directory.path, excludes: [])?.run { _ in }
        let replacementDirectory = directory.appendingPathComponent("replacement")
        try? FileManager.default.createDirectory(at: replacementDirectory, withIntermediateDirectories: true)
        try? Data(repeating: 67, count: 49152).write(to: replacementDirectory.appendingPathComponent("new-tree-only.txt"))
        let replacement = await ScanSession(root: replacementDirectory.path, excludes: [])?.run { _ in }
        let model = AppModel(); model.tree = tree
        let prior = DemoInput.window
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 520, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "CI actual mounted treemap tree swap"
        let barrier = PublicationBarrier("treemap"), results = Results(), probe = TreemapPublicationProbe()
        probe.before = { token, generation, requestedSize, requestedTreeID, requestedFilterID in
            if requestedSize == CGSize(width: 520, height: 300), requestedTreeID == tree.map(ObjectIdentifier.init) { await barrier.before("treemap", generation, token) }
        }
        probe.after = { token, generation, requestedSize, requestedTreeID, requestedFilterID, accepted, evidence in
            results.values.append((token, generation, requestedSize, requestedTreeID, requestedFilterID, accepted, evidence))
            Task { await barrier.after("treemap", generation, token) }
            Perf.log("treemap-tree-swap token=\(token) generation=\(generation) requestedSize=\(requestedSize) requestedTreeID=\(requestedTreeID) requestedFilterID=\(String(describing: requestedFilterID)) accepted=\(accepted) layout=\(String(describing: evidence.layoutID)) tree=\(String(describing: evidence.treeID)) publishedFilterID=\(String(describing: evidence.filterID)) size=\(evidence.size) hitValid=\(evidence.hitValid)")
        }
        let host = NSHostingView(rootView: TreemapView(publicationProbe: probe).environment(model))
        window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
        defer { probe.before = nil; probe.after = nil; probe.readEvidence = nil; window.close(); prior?.makeKeyAndOrderFront(nil) }
        let parked = await PublicationRegression.wait { await barrier.parked() }
        guard parked else {
            await barrier.release()
            Check.expect("treemap-mounted-new-tree-published", false, "520x300 request did not park; inconclusive lifecycle fixture")
            return
        }
        let oldToken = await barrier.heldToken()
        model.tree = replacement; model.selected = nil; model.revision += 1
        func validNew(_ value: (token: UUID, generation: UInt64, requestedSize: CGSize, requestedTreeID: ObjectIdentifier, requestedFilterID: ObjectIdentifier?, accepted: Bool, evidence: TreemapPublicationEvidence)) -> Bool {
            value.accepted && value.requestedTreeID == replacement.map(ObjectIdentifier.init) && value.requestedSize == CGSize(width: 520, height: 300) && value.evidence.size == value.requestedSize && value.evidence.treeID == replacement.map(ObjectIdentifier.init) && value.evidence.layoutID != nil && value.evidence.hitValid
        }
        let newer = await PublicationRegression.wait { results.values.contains(where: validNew) }
        try? await Task.sleep(nanoseconds: 700_000_000) // yield for Canvas rendering; pixels remain decisive
        let newState = results.values.last(where: validNew)
        let beforeCapture = probe.readEvidence?()
        let stillHeld = !(await barrier.completed())
        Check.expect("treemap-mounted-new-tree-published", tree != nil && replacement != nil && tree !== replacement && newer && stillHeld && window.isVisible && host.window === window && beforeCapture?.layoutID == newState?.evidence.layoutID && beforeCapture?.treeID == replacement.map(ObjectIdentifier.init) && beforeCapture?.size == CGSize(width: 520, height: 300) && beforeCapture?.hitValid == true, "actual Rust layout + hosted view; pixels43 required")
        guard newer, stillHeld, let newState else { await barrier.release(); return }
        capture(43)
        await barrier.release()
        let attempted = await PublicationRegression.wait { await barrier.completed() }
        try? await Task.sleep(nanoseconds: 700_000_000) // allow rendered state to settle before44
        let old = results.values.last { $0.token == oldToken && !$0.accepted }
        let afterCapture = probe.readEvidence?()
        Check.expect("treemap-mounted-old-tree-rejected-preserves-hit", attempted && old?.requestedTreeID == tree.map(ObjectIdentifier.init) && newState.requestedTreeID == replacement.map(ObjectIdentifier.init) && old?.requestedSize == CGSize(width: 520, height: 300) && (old?.generation ?? UInt64.max) < newState.generation && old?.evidence.layoutID == newState.evidence.layoutID && old?.evidence.treeID == newState.evidence.treeID && old?.evidence.size == newState.evidence.size && old?.evidence.hitValid == true && afterCapture?.layoutID == newState.evidence.layoutID && afterCapture?.treeID == newState.evidence.treeID && afterCapture?.size == newState.evidence.size && afterCapture?.hitValid == true, "token-specific old callback ran; actual currentLayout/hit path; pixels44 required")
        capture(44)
    }
}

@MainActor private enum TreemapMountedFilterRegression {
    final class Results {
        var values: [(token: UUID, generation: UInt64, requestedSize: CGSize, requestedTreeID: ObjectIdentifier, requestedFilterID: ObjectIdentifier?, accepted: Bool, evidence: TreemapPublicationEvidence)] = []
    }
    static func run(capture: (Int) -> Void) async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spz-mounted-filter-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try? Data(repeating: 65, count: 32768).write(to: directory.appendingPathComponent("keep-only.txt"))
        try? Data(repeating: 66, count: 16384).write(to: directory.appendingPathComponent("excluded.bin"))
        let tree = await ScanSession(root: directory.path, excludes: [])?.run { _ in }
        let model = AppModel(); model.tree = tree
        let prior = DemoInput.window
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 520, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "CI actual mounted treemap filter publication"
        let barrier = PublicationBarrier("treemap"), results = Results(), probe = TreemapPublicationProbe()
        probe.before = { token, generation, requestedSize, requestedTreeID, requestedFilterID in
            if requestedSize == CGSize(width: 520, height: 300), requestedTreeID == tree.map(ObjectIdentifier.init), requestedFilterID == nil { await barrier.before("treemap", generation, token) }
        }
        probe.after = { token, generation, requestedSize, requestedTreeID, requestedFilterID, accepted, evidence in
            results.values.append((token, generation, requestedSize, requestedTreeID, requestedFilterID, accepted, evidence))
            Task { await barrier.after("treemap", generation, token) }
            Perf.log("treemap-filter token=\(token) generation=\(generation) requestedSize=\(requestedSize) requestedTreeID=\(requestedTreeID) requestedFilterID=\(String(describing: requestedFilterID)) accepted=\(accepted) layout=\(String(describing: evidence.layoutID)) tree=\(String(describing: evidence.treeID)) publishedFilterID=\(String(describing: evidence.filterID)) size=\(evidence.size) hitValid=\(evidence.hitValid)")
        }
        let host = NSHostingView(rootView: TreemapView(publicationProbe: probe).environment(model))
        window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
        defer { probe.before = nil; probe.after = nil; probe.readEvidence = nil; window.close(); prior?.makeKeyAndOrderFront(nil) }
        let parked = await PublicationRegression.wait { await barrier.parked() }
        guard parked else {
            await barrier.release()
            Check.expect("treemap-mounted-new-filter-published", false, "520x300 request did not park; inconclusive lifecycle fixture")
            return
        }
        let oldToken = await barrier.heldToken()
        model.filterExt = "txt"
        let filterReady = await PublicationRegression.wait { !model.filterPending && model.activeFilter?.totalCount == 1 }
        let filterID = model.activeFilter.map(ObjectIdentifier.init)
        func validNew(_ value: (token: UUID, generation: UInt64, requestedSize: CGSize, requestedTreeID: ObjectIdentifier, requestedFilterID: ObjectIdentifier?, accepted: Bool, evidence: TreemapPublicationEvidence)) -> Bool {
            value.accepted && filterReady && filterID != nil && value.requestedFilterID == filterID && value.evidence.filterID == filterID && value.requestedTreeID == tree.map(ObjectIdentifier.init) && value.requestedSize == CGSize(width: 520, height: 300) && value.evidence.size == value.requestedSize && value.evidence.treeID == tree.map(ObjectIdentifier.init) && value.evidence.layoutID != nil && value.evidence.hitValid
        }
        let newer = await PublicationRegression.wait { results.values.contains(where: validNew) }
        try? await Task.sleep(nanoseconds: 700_000_000) // yield for Canvas rendering; pixels remain decisive
        let newState = results.values.last(where: validNew)
        let beforeCapture = probe.readEvidence?()
        let stillHeld = !(await barrier.completed())
        Check.expect("treemap-mounted-new-filter-published", tree != nil && filterReady && newer && stillHeld && window.isVisible && host.window === window && beforeCapture?.layoutID == newState?.evidence.layoutID && beforeCapture?.treeID == tree.map(ObjectIdentifier.init) && beforeCapture?.filterID == filterID && beforeCapture?.size == CGSize(width: 520, height: 300) && beforeCapture?.hitValid == true, "actual Rust layout + hosted view; pixels45 required")
        guard newer, stillHeld, let newState else { await barrier.release(); return }
        capture(45)
        await barrier.release()
        let attempted = await PublicationRegression.wait { await barrier.completed() }
        try? await Task.sleep(nanoseconds: 700_000_000) // allow rendered state to settle before46
        let old = results.values.last { $0.token == oldToken && !$0.accepted }
        let afterCapture = probe.readEvidence?()
        Check.expect("treemap-mounted-old-filter-rejected-preserves-hit", attempted && old?.requestedTreeID == tree.map(ObjectIdentifier.init) && old?.requestedFilterID == nil && newState.requestedFilterID == filterID && newState.requestedTreeID == tree.map(ObjectIdentifier.init) && old?.requestedSize == CGSize(width: 520, height: 300) && (old?.generation ?? UInt64.max) < newState.generation && old?.evidence.layoutID == newState.evidence.layoutID && old?.evidence.treeID == newState.evidence.treeID && old?.evidence.filterID == newState.evidence.filterID && old?.evidence.size == newState.evidence.size && old?.evidence.hitValid == true && afterCapture?.layoutID == newState.evidence.layoutID && afterCapture?.treeID == newState.evidence.treeID && afterCapture?.size == newState.evidence.size && afterCapture?.filterID == filterID && afterCapture?.hitValid == true, "token-specific old callback ran; actual currentLayout/hit path; pixels46 required")
        capture(46)
    }
}

@MainActor private enum TreemapUnmountRegression {
    @Observable final class MountState { var mounted = true }
    struct Surface: View {
        let state: MountState
        let model: AppModel
        let probe: TreemapPublicationProbe
        var body: some View {
            if state.mounted { TreemapView(publicationProbe: probe).environment(model) }
            else { Text("Treemap unmounted; pending old publication must not return").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }
    static func run(capture: (Int) -> Void) async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spz-unmount-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try? Data(repeating: 65, count: 32768).write(to: directory.appendingPathComponent("old-pending.txt"))
        let tree = await ScanSession(root: directory.path, excludes: [])?.run { _ in }
        let model = AppModel(); model.tree = tree
        let prior = DemoInput.window, state = MountState(), probe = TreemapPublicationProbe(), barrier = PublicationBarrier("unmount")
        let results = TreemapMountedRegression.Results()
        var disappeared: (UInt64, TreemapPublicationEvidence)? = nil
        probe.before = { token, generation, size, treeID, _ in
            if size == CGSize(width: 520, height: 300), treeID == tree.map(ObjectIdentifier.init) { await barrier.before("unmount", generation, token) }
        }
        probe.after = { token, generation, size, treeID, filterID, accepted, evidence in
            results.values.append((token, generation, size, treeID, filterID, accepted, evidence))
            Task { await barrier.after("unmount", generation, token) }
            Perf.log("treemap-unmount token=\(token) requestedGeneration=\(generation) requestedTreeID=\(treeID) accepted=\(accepted) layout=\(String(describing: evidence.layoutID)) tree=\(String(describing: evidence.treeID)) size=\(evidence.size)")
        }
        probe.disappeared = { generation, evidence in
            disappeared = (generation, evidence)
            Perf.log("treemap-unmount onDisappear generation=\(generation) layout=\(String(describing: evidence.layoutID))")
        }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 520, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "CI actual treemap unmount"
        let host = NSHostingView(rootView: Surface(state: state, model: model, probe: probe))
        window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
        defer { probe.before = nil; probe.after = nil; probe.readEvidence = nil; probe.disappeared = nil; window.close(); prior?.makeKeyAndOrderFront(nil) }
        let parked = await PublicationRegression.wait { await barrier.parked() }
        guard parked else { await barrier.release(); Check.expect("treemap-real-unmount-before-old-publication", false, "old computation did not park"); return }
        let token = await barrier.heldToken()
        state.mounted = false
        let didDisappear = await PublicationRegression.wait { disappeared != nil }
        try? await Task.sleep(nanoseconds: 700_000_000)
        let held = !(await barrier.completed())
        Check.expect("treemap-real-unmount-before-old-publication", didDisappear && held && !state.mounted && disappeared?.1.layoutID == nil && window.isVisible, "actual conditional host removal/onDisappear; pixels47 required")
        guard didDisappear, held else { await barrier.release(); return }
        capture(47)
        await barrier.release()
        let completed = await PublicationRegression.wait { await barrier.completed() }
        try? await Task.sleep(nanoseconds: 700_000_000)
        let old = results.values.last { $0.token == token }
        Check.expect("treemap-unmounted-old-publication-rejected", completed && old?.accepted == false && old?.requestedTreeID == tree.map(ObjectIdentifier.init) && old?.evidence.layoutID == nil && old?.evidence.treeID == nil && old?.evidence.size == .zero && (old?.generation ?? UInt64.max) < (disappeared?.0 ?? 0) && !state.mounted, "exact old callback ran after real disappearance, no published layout; pixels48 required")
        capture(48)
    }
}

/// Test-only mutable counter shared with @Sendable publish barriers.
final class PanicBox: @unchecked Sendable { var value: UInt64; init(_ v: UInt64) { value = v } }

/// Thread-safe call counter for test mocks that run on a background task.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Test gate for parking the engine commit between the filesystem move and the table swap.
final class OpenGate: @unchecked Sendable {
    private let lock = NSLock(); private var o = false
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return o }
    func open() { lock.lock(); o = true; lock.unlock() }
}

final class BusyFlag: @unchecked Sendable {
    private let lock = NSLock(); private var b: Bool
    init(_ v: Bool) { b = v }
    var value: Bool { get { lock.lock(); defer { lock.unlock() }; return b } set { lock.lock(); b = newValue; lock.unlock() } }
}

/// CI-only driver (SPZ_DEMO + SPZ_AUTOSCAN + SPZ_CHECKS=ordering): runs ONLY the model-level ordering/coherence checks, verifies
/// the result set fails closed, writes result.txt and assertions.txt into the unique SPZ_RESULT_DIR and exits. Compiled only with SPZ_CI_TESTS; the
/// entry additionally needs the env vars below.
@MainActor enum OrderingDriver {
    /// Every check name that must appear exactly once as PASS. A check that silently does not run, runs twice, or is
    /// not listed here fails the run. Add a name here in the same change that adds a check.
    static let required: [String] = [
        "view-treemap-layout-gate-released-by-real-view",
        "view-treemap-pixels-change-after-removal",
        "view-outline-rows-mounted-match-published",
        "view-outline-selection-syncs-both-ways",
        "view-outline-removal-drops-row-and-clears-selection",
        "view-outline-filtered-expanded-removal-readouts-coherent",
        "view-outline-filtered-expanded-selection-and-neighbors",
        "view-outline-filtered-count-v-of-t-false-pair-and-all-match",
        "view-outline-last-match-removal-hides-folder",
        "engine-row-info-abi-matches-rust",
        "engine-inspect-abi-matches-rust",
        "review-model-version-change-drops-result-and-clears-progress",
        "review-model-newer-request-wins-and-late-result-is-ignored",
        "review-cancel-reaches-the-inner-read-and-clears-state",
        "engine-scanned-identity-matches-lstat-on-fixture",
        "view-poison-outline-cells-show-unavailable-not-stale-names",
        "view-poison-outline-latch-persists-in-mounted-table",
        "engine-old-tree-forget-advances-old-only-after-swap",
        "engine-concurrent-forgets-on-one-tree-no-lost-update",
        "async-removal-cancel-is-harmless-and-does-not-stop-the-move",
        "async-removal-failure-leaves-tree-untouched",
        "async-removal-commit-busy-marks-out-of-date-and-keeps-journal",
        "async-removal-commit-stale-marks-out-of-date-and-keeps-journal",
        "async-removal-forgets-after-success",
        "async-removal-main-actor-stays-responsive",
        "async-removal-tree-swapped-mid-move-skips-forget",
        "async-removal-vanished-original-reported-and-marked-out-of-date",
        "async-undo-after-rescan-restores-and-marks-out-of-date",
        "async-undo-attempted-after-commit-lands",
        "async-undo-collision-keeps-entry-and-overwrites-nothing",
        "async-undo-refused-while-commit-parked",
        "async-undo-restores-and-clears-entry",
        "commit-order-all-surfaces-required-before-unblock",
        "commit-order-busy-retry-bounded",
        "commit-order-busy-retry-new-inputs-reset",
        "commit-order-cell-values-published-with-rows",
        "commit-order-deadline-terminal-when-layout-missing",
        "commit-order-failure-after-fs-success-persistent-out-of-date",
        "commit-order-filter-parked-before-forget-late-publish-rejected",
        "commit-order-layout-not-renderable-releases",
        "commit-order-node-snapshot-withheld-while-pending",
        "commit-order-real-scan-published-before-parked-commit-finishes-marks-out-of-date-keeps-new-tree",
        "commit-order-replaced-tree-outcome-marked-not-dropped",
        "commit-order-retry-keys-change-with-version",
        "commit-order-scan-replacement-clears-published-totals",
        "commit-order-scan-started-before-fs-change-marked-out-of-date",
        "commit-order-subtree-state-reset",
        "commit-order-undo-during-commit-refused",
        "node-busy-6plus-placeholder-recovers-and-cancels-on-selection-change",
        "poison-idle-counter-move-observed-by-watch",
        "poison-latches-refuses-and-clears-spinner",
        "poison-refuses-parked-derived-publication",
        "race-old-derived-after-clear-rejected",
        "race-old-filter-after-newer-rejected",
        "race-old-outline-after-tree-clear-rejected",
        "race-old-outline-after-tree-swap-rejected",
        "race-old-scan-completion-after-new-scan-rejected",
        "race-old-scan-progress-after-new-scan-rejected",
        "retry-new-inputs-replace-pending-action",
        "retry-same-inputs-dedupes-to-one-fire",
        "zero-match-root-count-and-layout-data-contract",
        "zero-match-selection-removal-policy"
    ]
    static func run(tree: Tree) async -> Never {
        // Results go to a unique per-run directory chosen by the runner (SPZ_RESULT_DIR). Nothing shared is deleted or
        // overwritten: a missing, unwritable or non-empty directory is a failure before any check runs.
        let fm = FileManager.default
        guard let dir = ProcessInfo.processInfo.environment["SPZ_RESULT_DIR"], dir.hasPrefix("/"),
              (try? fm.contentsOfDirectory(atPath: dir))?.isEmpty == true else {
            FileHandle.standardError.write(Data("FAIL SPZ_RESULT_DIR missing, relative, or not an empty directory\n".utf8)); exit(3)
        }
        let resultPath = dir + "/result.txt"
        Check.path = dir + "/assertions.txt"
        // Hard timeout: a hang or deadlock is a failure, never a pass.
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
            try? "FAIL timeout\n".write(toFile: resultPath, atomically: true, encoding: .utf8); exit(2)
        }
        Check.results.removeAll()
        await PublicationRegression.run(tree: tree)
        await CommitOrderingRegression.run()
        await ZeroMatchRegression.run()
        await AsyncRemovalRegression.run()
        await MountedViewRegression.run()
        await MountedOutlineRegression.run()
        await MountedOutlineRegression.runFiltered()
        await MountedOutlineRegression.runFilteredCounts()
        var problems: [String] = []
        if Check.results.isEmpty { problems.append("no results recorded") }
        let fileOK = (try? String(contentsOfFile: Check.path, encoding: .utf8))?.isEmpty == false
        if !fileOK { problems.append("assertion file missing or empty") }
        let counts = Dictionary(grouping: Check.results, by: { $0.name })
        for r in required {
            let rs = counts[r] ?? []
            if rs.isEmpty { problems.append("missing: \(r)") }
            else if rs.count != 1 { problems.append("duplicate (\(rs.count)): \(r)") }
            else if !rs[0].ok { problems.append("FAIL: \(r)") }
        }
        let allowed = Set(required)
        for (n, rs) in counts where !allowed.contains(n) { problems.append("unlisted result \(n) ok=\(rs.map { $0.ok })") }
        for r in Check.results where !r.ok && allowed.contains(r.name) == false { problems.append("FAIL (unlisted): \(r.name)") }
        let body = problems.isEmpty ? "PASS \(required.count) required checks, each exactly once\n" : "FAIL\n" + problems.joined(separator: "\n") + "\n"
        try? body.write(toFile: resultPath, atomically: true, encoding: .utf8)
        exit(problems.isEmpty ? 0 : 1)
    }
}

#endif
