#if SPZ_CI_TESTS
import AppKit
import Foundation

// STAGED, UNCOMPILED, UNRUN. A separate mode in the same test binary, not a second build.
// Uses the mounted product ContentView/AppModel, real scan, filter, outline and treemap paths.
// Does not touch Trash or substitute synthetic engine results. Its runner must generate and
// verify scripts/make_fixtures.py expansion-1m first. Timing is shared-runner evidence only.
@MainActor enum LargeScanDriver {
    private static var started = false
    private static func wait(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    static func run(model: AppModel, env: [String: String]) async -> Never {
        guard !started else {
            FileHandle.standardError.write(Data("FAIL scale: duplicate app scene invocation\n".utf8))
            exit(3)
        }
        started = true
        let fm = FileManager.default
        guard let dir = env["SPZ_RESULT_DIR"], dir.hasPrefix("/"),
              (try? fm.contentsOfDirectory(atPath: dir))?.isEmpty == true,
              let root = env["SPZ_SCALE_ROOT"], root.hasPrefix("/"),
              fm.fileExists(atPath: root + "/expansion-1000000/zz_nested/inner_a") else {
            FileHandle.standardError.write(Data("FAIL scale: missing empty result directory or verified fixture root\n".utf8))
            exit(3)
        }
        Check.path = dir + "/assertions.txt"
        Check.results.removeAll()
        let required = ["scale-real-scan-exact-million-item-tree", "scale-mounted-million-row-publication",
                        "scale-filter-exact-single-file", "scale-clear-filter-restores-million-rows",
                        "scale-main-queue-delay-under-250ms"]
        // Hard process timeout, not a cancellation race with an uninterruptible engine poll.
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
            try? "FAIL scale driver timeout; no readiness claim\n".write(toFile: dir + "/result.txt", atomically: true, encoding: .utf8)
            exit(2)
        }
        func finish() -> Never {
            let groups = Dictionary(grouping: Check.results, by: { $0.name })
            let ok = Set(groups.keys) == Set(required) && required.allSatisfy {
                groups[$0]?.count == 1 && groups[$0]?.first?.ok == true
            }
            try? (ok ? "PASS 5 scale checks, each exactly once\n" : "FAIL scale checks\n").write(toFile: dir + "/result.txt", atomically: true, encoding: .utf8)
            exit(ok ? 0 : 1)
        }
        func failRemaining(_ after: Int, _ detail: String) -> Never {
            for n in required.dropFirst(after) { Check.expect(n, false, detail) }
            finish()
        }
        let probe = TreemapPublicationProbe()
        model.ciScaleTreemapProbe = probe
        func currentTreemap(_ tree: Tree, filter: FilterResult?) -> Bool {
            guard let evidence = probe.readEvidence?() else { return false }
            return evidence.layoutID != nil && evidence.treeID == ObjectIdentifier(tree)
                && evidence.filterID == filter.map(ObjectIdentifier.init) && evidence.hitValid
        }
        // Use the already-mounted app scene, not a second ContentView with the same model:
        // two tables would race the model's weak outlineKeyView reference.
        let mounted = await wait(5) { NSApp.windows.contains { $0.contentView != nil && $0.isVisible } }
        guard mounted else { failRemaining(0, "not reached: application window not mounted") }
        // Full mounted scan: wrapper root + profile directory + 1m files + nested dir + 2 files.
        let expectedNodes: UInt64 = 1_000_005
        let expectedRows = 1_000_002   // profile row + its direct children; nested stays collapsed.
        let clock = DispatchTime.now().uptimeNanoseconds
        let sampler = ScaleMainQueueSampler()
        sampler.start()
        model.scan(root)
        let scanned = await wait(90) { !model.scanning }
        let exact = scanned && model.error == nil && model.tree?.nodeCount == expectedNodes && model.tree?.wasCancelled == false
        Check.expect("scale-real-scan-exact-million-item-tree", exact,
                     "done=\(scanned) nodes=\(model.tree?.nodeCount ?? 0)/\(expectedNodes) error=\(model.error ?? "none")")
        guard exact, let tree = model.tree, let folder = tree.find(path: root + "/expansion-1000000") else {
            failRemaining(1, "not reached: real million-item scan premise failed")
        }
        // The product view, not the test, publishes layoutVersion. All versions must agree.
        let ready = await wait(20) {
            !model.filterPending && !model.rowsPending && model.outlineVersion == tree.version
                && model.derivedVersion == tree.version && model.layoutVersion == tree.version
                && model.outlineKeyView?.numberOfRows == 1 && currentTreemap(tree, filter: nil)
        }
        guard ready else { failRemaining(1, "not reached: mounted outline/derived/treemap initial publication failed") }
        model.toggle(folder)
        let expanded = await wait(20) {
            model.outlineRows.count == expectedRows && model.outlineKeyView?.numberOfRows == expectedRows
                && model.outlineInfos.count == expectedRows && model.outlineShown.count == expectedRows
                && model.outlineVersion == tree.version && !model.filterPending
        }
        // Read one actually realized last-row cell after a real table scroll. Do not enumerate
        // 1m accessibility objects (that would test a different, pathological harness workload).
        var lastCellMatches = false
        if expanded, let table = model.outlineKeyView, let node = model.outlineRows.last?.node {
            table.scrollRowToVisible(expectedRows - 1)
            let label = table.view(atColumn: 0, row: expectedRows - 1, makeIfNecessary: true)?.accessibilityLabel() ?? ""
            lastCellMatches = label.contains(tree.name(node)) && !tree.name(node).isEmpty
        }
        Check.expect("scale-mounted-million-row-publication", expanded && lastCellMatches,
                     "modelRows=\(model.outlineRows.count) tableRows=\(model.outlineKeyView?.numberOfRows ?? -1) lastRealCell=\(lastCellMatches)")
        guard expanded && lastCellMatches else { failRemaining(2, "not reached: expanded publication failed") }
        model.filterText = "f0000000.dat"
        let filtered = await wait(20) {
            !model.filterPending && model.activeFilter?.totalCount == 1
                && model.activeFilter?.version == tree.version && model.outlineVersion == tree.version
                && model.derivedVersion == tree.version
                && model.outlineRows.count == 2 && model.outlineKeyView?.numberOfRows == 2
                && currentTreemap(tree, filter: model.activeFilter)
        }
        let target = tree.find(path: root + "/expansion-1000000/f0000000.dat")
        Check.expect("scale-filter-exact-single-file", filtered && (target.map { id in model.outlineRows.contains { $0.node == id } } == true),
                     "filtered=\(filtered) matches=\(model.activeFilter?.totalCount ?? 0) rows=\(model.outlineRows.count)")
        guard filtered else { failRemaining(3, "not reached: exact filter failed") }
        model.filterText = ""
        let cleared = await wait(20) {
            !model.filterPending && model.activeFilter == nil && model.outlineRows.count == expectedRows
                && model.outlineKeyView?.numberOfRows == expectedRows && model.outlineVersion == tree.version
                && model.derivedVersion == tree.version && currentTreemap(tree, filter: nil)
        }
        Check.expect("scale-clear-filter-restores-million-rows", cleared, "cleared=\(cleared) rows=\(model.outlineRows.count)")
        // stopAndFlush serializes with enqueue, then flushes every pending ping on main.
        // A minimum sample count rejects absent/dead instrumentation instead of max=0 passing.
        let measured = await sampler.stopAndFlush()
        let summary = "main_queue_delay max_ms=\(measured.peak) samples=\(measured.samples)"
        Check.expect("scale-main-queue-delay-under-250ms", measured.samples >= 10 && measured.peak < 250, summary)
        var metrics = "nodes=\(expectedNodes) rows=\(expectedRows) wall_ms=\(Double(DispatchTime.now().uptimeNanoseconds - clock)/1e6)\n"
        metrics += summary + "\nScope: one shared runner; not p95, CPU-cause proof, full key/mouse event latency, or real-hardware signoff. Treemap checks read actual published layout tree/filter identities and a valid hit through the mounted view probe.\n"
        try? metrics.write(toFile: dir + "/scale-metrics.txt", atomically: true, encoding: .utf8)
        var snapshotWritten = false
        if let table = model.outlineKeyView {
            table.scrollRowToVisible(0)
            table.layoutSubtreeIfNeeded()
            if let view = table.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    do { try png.write(to: URL(fileURLWithPath: dir + "/scale-mounted-window.png")); snapshotWritten = true } catch { }
                }
            }
        }
        if !snapshotWritten {
            try? "FAIL scale: mounted snapshot missing\n".write(toFile: dir + "/result.txt", atomically: true, encoding: .utf8)
            exit(1)
        }
        finish()
    }
}

// Test-only single-outstanding ping sampler, not a production scheduler change.
private final class ScaleMainQueueSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var peak = 0.0
    private var samples = 0
    private let ready = DispatchSemaphore(value: 1)
    func start() {
        let worker = Thread { [self] in
            while true {
                ready.wait()
                lock.lock()
                if stopped { lock.unlock(); return }
                let sent = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.main.async { [self] in
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1e6
                    lock.lock(); peak = max(peak, ms); samples += 1; lock.unlock()
                    ready.signal()
                }
                lock.unlock()
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        worker.start()
    }
    func stopAndFlush() async -> (peak: Double, samples: Int) {
        // Lock ensures no ping can enqueue after the flush sentinel is enqueued.
        await withCheckedContinuation { continuation in
            lock.lock(); stopped = true
            DispatchQueue.main.async { [self] in
                lock.lock(); let result = (peak: peak, samples: samples); lock.unlock()
                continuation.resume(returning: result)
            }
            lock.unlock()
            ready.signal()
        }
    }
}
#endif
