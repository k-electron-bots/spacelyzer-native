import Foundation
import CSpacelyzer
// LINUX-ONLY probe (not a product check, not in the Mac manifest). Real AppModel + real Rust engine (Linux scan path).
// Aims at the model half of the Mac failure view-outline-removal-drops-row-and-clears-selection: after a removal settles,
// the removed node is gone from the tree, the published outline rows, the focus and the multi-selection. The mounted-table half is AppKit-only.
@MainActor enum RemovalSelectionProbe {
    static func settle(_ c: @MainActor () -> Bool) async { for _ in 0..<500 where !c() { try? await Task.sleep(nanoseconds: 10_000_000) } }
    static func surfaces(_ m: AppModel) async -> Bool {
        _ = await m.settleRemoval()
        await settle { m.outlineVersion == m.tree?.version && m.derivedVersion == m.tree?.version }
        if let v = m.tree?.version { m.layoutPublished(v) }
        await settle { !m.rowsPending }
        return !m.rowsPending && m.requiredVersion == nil
    }
    static func fixture() -> (String, URL) {
        let fm = FileManager.default
        let d = fm.temporaryDirectory.appendingPathComponent("spz-rsp-\(UUID().uuidString)")
        try! fm.createDirectory(at: d, withIntermediateDirectories: true)
        for (n, k) in [("big.bin", 40_000), ("mid.bin", 20_000), ("small.bin", 8_000), ("tiny.bin", 1_000)] { try! Data(repeating: 5, count: k).write(to: d.appendingPathComponent(n)) }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX)); precondition(realpath(d.path, &buf) != nil)
        return (String(cString: buf), d)
    }
    static func primed(_ m: AppModel) async -> AppModel {
        m.refreshOutline(); await settle { !m.outlineRows.isEmpty }; _ = await surfaces(m); return m
    }
    static func model(_ t: Tree) -> AppModel {
        let m = AppModel(); m.tree = t
        m.trashItem = { url in let to = url.appendingPathExtension("trashed"); try FileManager.default.moveItem(at: url, to: to); return to }
        m.identityCheck = { _, _ in .same }
        return m
    }
    static func run() async {
        let (root, dir) = fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        guard let t = await ScanSession(root: root, excludes: [])?.run(progress: { _ in }) else { Check.expect("probe-fixture-scan", false, ""); return }
        func ids(_ m: AppModel) -> Set<UInt32> { Set(m.outlineRows.map { $0.node }) }
        // 1. The mounted-outline scenario, model half: focus on big, remove it, settle.
        do {
            let m = await primed(model(t))
            let big = t.find(path: "\(root)/big.bin")!
            m.selectOnly(big)
            let before = ids(m).contains(big) && m.selected == big
            m.proposeRemoval(of: big); let pend = m.pendingRemoval != nil; m.confirmRemoval(); await m.removalTask?.value
            let quiet = await surfaces(m)
            let live = m.tree.map { $0.find(path: "\(root)/big.bin") == nil } ?? false
            Check.expect("probe-removal-drops-row-clears-focus-and-set",
                         before && quiet && !ids(m).contains(big) && m.selected != big && !m.selectedSet.contains(big) && ["mid","small","tiny"].allSatisfy { n in m.tree!.find(path: "\(root)/\(n).bin") != nil },
                         "pend=\(pend) blocked=\(String(describing: m.removalBlockedReason(big))) msg=\(m.removalMessage ?? "nil") before=\(before) quiet=\(quiet) liveGone=\(live) rowStill=\(ids(m).contains(big)) sel=\(String(describing: m.selected)) set=\(m.selectedSet)")
        }
        // 2. Stress: remove each file in turn while the selection moves around; after every settle every selected id must be live and every row id must be live.
        var bad = ""
        for order in [["big","mid","small"], ["tiny","big","mid"], ["small","tiny","big"], ["mid","small","tiny"]] {
            let (r2, d2) = fixture(); defer { try? FileManager.default.removeItem(at: d2) }
            guard let t2 = await ScanSession(root: r2, excludes: [])?.run(progress: { _ in }) else { bad += " scan"; continue }
            let m = await primed(model(t2))
            for n in order {
                let p = "\(r2)/\(n).bin"
                guard let tr = m.tree else { bad += " notree"; break }
                guard let id = tr.find(path: p) else { bad += " missing:\(n)"; break }
                // select this item plus every other live file, focus somewhere else sometimes
                let others = ["big","mid","small","tiny"].compactMap { k -> UInt32? in tr.find(path: "\(r2)/\(k).bin") }
                m.selectOnly(others.first!); for o in others.dropFirst() { m.selectToggle(o) }
                m.selected = id
                m.proposeRemoval(of: id); m.confirmRemoval()
                // selection churn while the removal is in flight
                m.selectOnly(id)
                _ = await surfaces(m)
                guard let t3 = m.tree else { bad += " notree2"; break }
                let live = Set(["big","mid","small","tiny"].compactMap { k -> UInt32? in t3.find(path: "\(r2)/\(k).bin") })
                                if let s = m.selected, s == id { bad += " \(n)-still-focused" }
                if m.selectedSet.contains(id) { bad += " \(n)-still-in-set" }
                if !Set(m.selectedSet).isSubset(of: live.union(Set(m.outlineRows.map { $0.node }))) { bad += " \(n)-set-has-dead-id" }
                if ids(m).contains(id) { bad += " \(n)-row-remains" }
            }
        }
        Check.expect("probe-removal-sequences-with-selection-churn-leave-no-stale-ids", bad.isEmpty, bad)
    }
}
