#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import CSpacelyzer   // SpzRow comes from the C target, like the production files
import Foundation

// UNCOMPILED and UNRUN until a Mac run. Checks for the guarded batch-removal epic's sixth slice:
// one Undo action restores every item the last batch moved in a single restore pass through the
// same seams as the per-item undo; a collided item keeps its journal entry while the rest restore;
// the duplicates-review whole-set action plans with the batch keep-one rule (the copy whose path
// sorts first is always kept) and executes through the same per-item identity-checked Trash path;
// and a later single removal clears the batch-undo hint. Deterministic: scanned fixture trees, a
// fresh AppModel per case, Trash/identity/probe/restore seams mocked - nothing touches the real
// Trash and no panel is shown.
@MainActor
enum BatchUndoChecks {
    /// Bounded: polls cond for about 3 s.
    private static func settle(_ cond: @MainActor () -> Bool) async { for _ in 0..<300 where !cond() { try? await Task.sleep(nanoseconds: 10_000_000) } }
    /// Acts as the missing view exactly once per settled removal (the same pattern the removal-history
    /// suite uses): the layout surface publishes the current version, then the model must go quiet.
    /// Returns false when the model never goes quiet; the caller's check then fails on its own terms.
    private static func settleSurfaces(_ m: AppModel) async -> Bool {
        _ = await m.settleRemoval()
        await settle { m.outlineVersion == m.tree?.version && m.derivedVersion == m.tree?.version }
        if let v = m.tree?.version { m.layoutPublished(v) }
        await settle { !m.rowsPending }
        return !m.rowsPending && m.requiredVersion == nil
    }

    static func run() async {
        let fm = FileManager.default

        // Fixture 1: three distinct files, shared by the batch-undo and hint cases (one model per
        // case; the journal and hint live on the model, not the tree).
        let d1 = fm.temporaryDirectory.appendingPathComponent("spz-bundo-\(UUID().uuidString)")
        try! fm.createDirectory(at: d1, withIntermediateDirectories: true)
        try! Data(repeating: 1, count: 1_000).write(to: d1.appendingPathComponent("a.bin"))
        try! Data(repeating: 2, count: 2_000).write(to: d1.appendingPathComponent("b.bin"))
        try! Data(repeating: 3, count: 3_000).write(to: d1.appendingPathComponent("c.bin"))
        defer { try? fm.removeItem(at: d1) }
        // The engine canonicalizes the scan root (engine/src/scan.rs: root.canonicalize(), realpath(3)
        // semantics); NSString's resolvingSymlinksInPath does NOT resolve /var -> /private/var (run
        // 38404596442). Canonicalize with the same syscall, fail loudly if it fails, then PROVE the form
        // matches the engine-stored root (t.path(0)) instead of assuming it.
        // Wrapped in a local function so a fixture-1 failure cannot skip fixture 2: every listed
        // check name must be emitted on every path through this suite.
        func batchUndoAndHintChecks() async {
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(d1.path, &buf) != nil else {
                let err = String(cString: strerror(errno))
                for n in ["batch-undo-restores-whole-batch-in-one-pass",
                          "batch-undo-collision-keeps-that-item-in-history",
                          "single-removal-clears-batch-undo-hint"] { Check.expect(n, false, "realpath failed for \(d1.path): \(err)") }
                return
            }
            let root1 = String(cString: buf)
            guard let t1 = await ScanSession(root: root1, excludes: [])?.run(progress: { _ in }) else {
                for n in ["batch-undo-restores-whole-batch-in-one-pass",
                          "batch-undo-collision-keeps-that-item-in-history",
                          "single-removal-clears-batch-undo-hint"] { Check.expect(n, false, "fixture scan") }
                return
            }
            let engineRoot = t1.path(0)
            guard engineRoot == root1 else {
                for n in ["batch-undo-restores-whole-batch-in-one-pass",
                          "batch-undo-collision-keeps-that-item-in-history",
                          "single-removal-clears-batch-undo-hint"] { Check.expect(n, false, "path-form mismatch engine=\(engineRoot) fixture=\(root1)") }
                return
            }
            guard let a = t1.find(path: "\(root1)/a.bin"), let b = t1.find(path: "\(root1)/b.bin"),
                  let c = t1.find(path: "\(root1)/c.bin"), a != 0, b != 0, c != 0 else {
                for n in ["batch-undo-restores-whole-batch-in-one-pass",
                          "batch-undo-collision-keeps-that-item-in-history",
                          "single-removal-clears-batch-undo-hint"] { Check.expect(n, false, "fixture find") }
                return
            }
            func model3() -> AppModel {
                let m = AppModel()
                m.tree = t1
                m.outlineRows = [a, b, c].map { SpzRow(node: $0, depth: 1) }
                m.outlineIndex = Dictionary(uniqueKeysWithValues: [a, b, c].enumerated().map { ($0.element, $0.offset) })
                m.selectOnly(a); m.selectToggle(b); m.selectToggle(c)
                return m
            }

            // 1. One Undo restores the whole last batch in a single pass, in journal order.
            let m1 = model3()
            m1.trashItem = { url in url.appendingPathExtension("trashed") }
            m1.identityCheck = { _, _ in .same }
            m1.restoreCollisionProbe = { _ in false }
            var restored1: [(String, String)] = []
            m1.restoreItem = { from, to in restored1.append((from.lastPathComponent, to.lastPathComponent)) }
            m1.proposeBatchRemoval()
            m1.confirmBatchRemoval()
            await m1.removalTask?.value
            let journaled = m1.lastRemoved.count, hintBefore = m1.lastBatchCount ?? -1
            _ = await settleSurfaces(m1)   // a settled removal keeps requiredVersion set until a view publishes; the suite acts as that view
            m1.undoBatchRemoval()
            await m1.removalTask?.value
            Check.expect("batch-undo-restores-whole-batch-in-one-pass",
                         journaled == 3 && hintBefore == 3
                         && restored1.map { "\($0.0)>\($0.1)" } == ["a.bin.trashed>a.bin", "b.bin.trashed>b.bin", "c.bin.trashed>c.bin"]
                         && m1.lastRemoved.isEmpty && m1.lastBatchCount == nil && m1.removalMessage != nil,
                         "journaled=\(journaled) hint=\(hintBefore) restored=\(restored1) left=\(m1.lastRemoved.count) msg=\(m1.removalMessage ?? "nil")")

            // 2. A collided item keeps its journal entry; the rest of the batch restores.
            let m2 = model3()
            m2.trashItem = { url in url.appendingPathExtension("trashed") }
            m2.identityCheck = { _, _ in .same }
            m2.restoreCollisionProbe = { path in path.hasSuffix("/b.bin") }
            var restored2: [String] = []
            m2.restoreItem = { _, to in restored2.append(to.lastPathComponent) }
            m2.proposeBatchRemoval()
            m2.confirmBatchRemoval()
            await m2.removalTask?.value
            _ = await settleSurfaces(m2)
            m2.undoBatchRemoval()
            await m2.removalTask?.value
            let kept = m2.lastRemoved.map { $0.original.lastPathComponent }
            Check.expect("batch-undo-collision-keeps-that-item-in-history",
                         restored2 == ["a.bin", "c.bin"] && kept == ["b.bin"]
                         && (m2.removalMessage ?? "").contains("b.bin"),
                         "restored=\(restored2) kept=\(kept) msg=\(m2.removalMessage ?? "nil")")

            // 5 (run here, same fixture): a single removal after a batch clears the batch-undo hint.
            let m5 = model3()
            m5.trashItem = { url in url.appendingPathExtension("trashed") }
            m5.identityCheck = { _, _ in .same }
            m5.restoreCollisionProbe = { _ in false }
            m5.restoreItem = { _, _ in }
            m5.selectOnly(a); m5.selectToggle(b)          // batch of two only
            m5.proposeBatchRemoval()
            m5.confirmBatchRemoval()
            await m5.removalTask?.value
            _ = await settleSurfaces(m5)
            let hintAfterBatch = m5.lastBatchCount ?? -1
            m5.proposeRemoval(of: c)
            let proposed = m5.pendingRemoval != nil
            m5.confirmRemoval()
            Check.expect("single-removal-clears-batch-undo-hint",
                         hintAfterBatch == 2 && proposed && m5.lastBatchCount == nil,
                         "hintAfterBatch=\(hintAfterBatch) proposed=\(proposed) hint=\(String(describing: m5.lastBatchCount))")
        }
        await batchUndoAndHintChecks()

        // Fixture 2: one duplicate pair, for the whole-set plan and execution cases.
        let d2 = fm.temporaryDirectory.appendingPathComponent("spz-bgrp-\(UUID().uuidString)")
        try! fm.createDirectory(at: d2, withIntermediateDirectories: true)
        try! Data(repeating: 9, count: 1_500).write(to: d2.appendingPathComponent("dupA.bin"))
        try! Data(repeating: 9, count: 1_500).write(to: d2.appendingPathComponent("dupB.bin"))
        defer { try? fm.removeItem(at: d2) }
        var buf2 = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(d2.path, &buf2) != nil else {
            let err = String(cString: strerror(errno))
            for n in ["group-removal-plan-keeps-one-copy-deterministically",
                      "group-removal-executes-through-same-per-item-path"] { Check.expect(n, false, "realpath failed for \(d2.path): \(err)") }
            return
        }
        let root2 = String(cString: buf2)
        guard let t2 = await ScanSession(root: root2, excludes: [])?.run(progress: { _ in }) else {
            for n in ["group-removal-plan-keeps-one-copy-deterministically",
                      "group-removal-executes-through-same-per-item-path"] { Check.expect(n, false, "fixture scan") }
            return
        }
        let engineRoot2 = t2.path(0)
        guard engineRoot2 == root2 else {
            for n in ["group-removal-plan-keeps-one-copy-deterministically",
                      "group-removal-executes-through-same-per-item-path"] { Check.expect(n, false, "path-form mismatch engine=\(engineRoot2) fixture=\(root2)") }
            return
        }
        guard t2.find(path: "\(root2)/dupA.bin") != nil, t2.find(path: "\(root2)/dupB.bin") != nil else {
            for n in ["group-removal-plan-keeps-one-copy-deterministically",
                      "group-removal-executes-through-same-per-item-path"] { Check.expect(n, false, "fixture find") }
            return
        }
        let group = ["\(root2)/dupA.bin", "\(root2)/dupB.bin"]
        func groupModel() -> AppModel { let m = AppModel(); m.tree = t2; return m }

        // 3. Whole-set planning keeps one copy deterministically: the copy whose path sorts first
        //    (dupA) is refused by the batch keep-one rule; dupB is the single approved item.
        let m3 = groupModel()
        m3.proposeGroupRemoval(group)
        let plan = m3.pendingBatchRemoval
        Check.expect("group-removal-plan-keeps-one-copy-deterministically",
                     plan?.items.map(\.path) == ["\(root2)/dupB.bin"]
                     && plan?.refused.count == 1
                     && plan?.refused.first?.path == "\(root2)/dupA.bin"
                     && (plan?.refused.first?.reason.contains("One copy is always kept.") ?? false),
                     "items=\(plan?.items.map(\.path) ?? []) refused=\(plan?.refused ?? [])")

        // 4. Whole-set execution goes through the same per-item identity-checked Trash path and
        //    journals the moved copy.
        let m4 = groupModel()
        var trashed4: [String] = []
        m4.trashItem = { url in trashed4.append(url.lastPathComponent); return url.appendingPathExtension("trashed") }
        m4.identityCheck = { _, _ in .same }
        m4.restoreCollisionProbe = { _ in false }
        m4.restoreItem = { _, _ in }
        m4.proposeGroupRemoval(group)
        m4.confirmBatchRemoval()
        await m4.removalTask?.value
        Check.expect("group-removal-executes-through-same-per-item-path",
                     trashed4 == ["dupB.bin"] && m4.lastRemoved.count == 1
                     && m4.lastRemoved.first?.original.lastPathComponent == "dupB.bin"
                     && m4.removalMessage == "Moved 1 of 1 items to the Trash.",
                     "trashed=\(trashed4) journal=\(m4.lastRemoved.count) msg=\(m4.removalMessage ?? "nil")")
    }
}
#endif
