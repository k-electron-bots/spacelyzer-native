#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import Foundation

// UNCOMPILED and UNRUN until a Mac run. Regression checks for DuplicatesModel: the
// duplicate pass reads file contents and blocks its thread (minutes on a large tree), so
// the read must run OFF the main actor, publish ON it, cancel() must suppress a late
// publish, a failed read is a failed read never an empty answer, a cancelled pass renders
// cancelled never partial numbers, and a capped report keeps its partial label data.
// Deterministic: bounded gates, no sleeps. The reader is injected (a parked synthetic
// answer); engine duplicate-finding itself is covered by the Linux engine tests, not here.
@MainActor
enum DuplicatesChecks {
    /// Bounded: wait() returns when opened or after about 5 s, whichever is first. A gate
    /// nobody opens makes the check FAIL, never hang the run.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock(); private var opened = false
        func wait() async { for _ in 0..<500 where !isOpen { try? await Task.sleep(nanoseconds: 10_000_000) } }
        func open() { lock.lock(); opened = true; lock.unlock() }
        var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return opened }
    }
    /// Bounded: polls cond for about 3 s.
    private static func settle(_ cond: () -> Bool) async { for _ in 0..<300 where !cond() { try? await Task.sleep(nanoseconds: 10_000_000) } }
    private static func fixture(_ tag: String, _ files: [(String, Int)]) -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("spz-dpc-\(tag)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for (name, size) in files { try! Data(repeating: 7, count: size).write(to: d.appendingPathComponent(name)) }
        return d
    }

    static func run() async {
        let names = ["duplicates-load-runs-off-main-and-publishes-on-main", "duplicates-cancel-suppresses-late-publish",
                     "duplicates-failed-read-shows-failed-never-empty", "duplicates-cancelled-pass-renders-cancelled-never-partial-numbers",
                     "duplicates-capped-report-keeps-partial-label-data"]
        let d = fixture("duplicates", [("a.bin", 30_000), ("b.bin", 30_000)])
        defer { try? FileManager.default.removeItem(at: d) }
        guard let t = await ScanSession(root: d.path, excludes: [])?.run(progress: { _ in }) else {
            for n in names { Check.expect(n, false, "fixture") }; return
        }
        let whole = DupSummary(duplicateAllocatedBytes: 60_000, groupsTotal: 1, groupsListed: 1, unreadable: 0, changed: 0,
                               hardlinkAliases: 0, cancelled: false, incomplete: false, budgetExhausted: false, groupsTruncated: false)
        let one = DupFindResult(summary: whole, groups: [DupGroup(size: 30_000, memberCount: 2, linked: false, paths: ["\(d.path)/a.bin", "\(d.path)/b.bin"])])

        // 1. load() returns while the pass is parked off-main (a synchronous pass would park
        // the caller here), then publishes exactly what the reader answered once the gate opens.
        let g1 = Gate()
        let m1 = DuplicatesModel(reader: { _, _ in await g1.wait(); return .success(one) })
        m1.load(tree: t)
        let returnedParked = !g1.isOpen && m1.result == nil && !m1.readFailed && !m1.cancelled && m1.token == 1
        g1.open()
        await settle { m1.processedTokens.contains(1) }
        let published = m1.result == one && !m1.readFailed && !m1.cancelled
        Check.expect("duplicates-load-runs-off-main-and-publishes-on-main", returnedParked && published && m1.processedTokens.contains(1), "returnedParked=\(returnedParked) published=\(published)")

        // 2. cancel() while the pass is parked: the late answer is processed but never published.
        let g2 = Gate()
        let m2 = DuplicatesModel(reader: { _, _ in await g2.wait(); return .success(one) })
        m2.load(tree: t)
        let tok2 = m2.token
        m2.cancel()
        g2.open()
        await settle { m2.processedTokens.contains(tok2) }
        Check.expect("duplicates-cancel-suppresses-late-publish", m2.processedTokens.contains(tok2) && m2.result == nil && !m2.readFailed && !m2.cancelled, "processed=\(m2.processedTokens.contains(tok2)) result=\(m2.result == nil ? "nil" : "set")")

        // 3. A failed read is a failed read, never an empty answer.
        let m3 = DuplicatesModel(reader: { _, _ in .failure(.invalid) })
        m3.load(tree: t)
        await settle { m3.processedTokens.contains(1) }
        Check.expect("duplicates-failed-read-shows-failed-never-empty", m3.readFailed && m3.result == nil && !m3.cancelled, "readFailed=\(m3.readFailed) result=\(m3.result == nil ? "nil" : "set")")

        // 4. A cancelled pass renders cancelled, never partial numbers.
        let cxlSummary = DupSummary(duplicateAllocatedBytes: 60_000, groupsTotal: 1, groupsListed: 1, unreadable: 0, changed: 0,
                                    hardlinkAliases: 0, cancelled: true, incomplete: true, budgetExhausted: false, groupsTruncated: false)
        let m4 = DuplicatesModel(reader: { _, _ in .success(DupFindResult(summary: cxlSummary, groups: one.groups)) })
        m4.load(tree: t)
        await settle { m4.processedTokens.contains(1) }
        Check.expect("duplicates-cancelled-pass-renders-cancelled-never-partial-numbers", m4.cancelled && m4.result == nil && !m4.readFailed, "cancelled=\(m4.cancelled) result=\(m4.result == nil ? "nil" : "set")")

        // 5. A capped report publishes with partial == true, so the view labels it partial.
        let cappedSummary = DupSummary(duplicateAllocatedBytes: 60_000, groupsTotal: 5, groupsListed: 1, unreadable: 0, changed: 0,
                                       hardlinkAliases: 0, cancelled: false, incomplete: false, budgetExhausted: false, groupsTruncated: true)
        let m5 = DuplicatesModel(reader: { _, _ in .success(DupFindResult(summary: cappedSummary, groups: one.groups)) })
        m5.load(tree: t)
        await settle { m5.processedTokens.contains(1) }
        Check.expect("duplicates-capped-report-keeps-partial-label-data", m5.result?.summary.partial == true && m5.result?.summary.groupsTotal == 5 && m5.result?.summary.groupsListed == 1, "partial=\(String(describing: m5.result?.summary.partial))")
    }
}
#endif
