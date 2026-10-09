#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import Foundation

// UNCOMPILED and UNRUN until a Mac run. Regression checks for SkippedListModel (verifier finding on
// the skipped-list slice): the read must run OFF the main actor - one FFI call per skipped entry, so at
// 100k+ entries a main-actor read stalls the UI before the ProgressView can render - the publish must be
// on the main actor, and cancel() must suppress a late publish. Deterministic: bounded gates, no sleeps.
// The reader is injected (a parked synthetic answer), so the tree is an opaque real fixture tree; engine
// skipped-list behavior itself is covered by the Linux engine tests, not here.
@MainActor
enum SkippedListChecks {
    /// Bounded: wait() returns when opened or after about 5 s, whichever is first. A gate nobody opens
    /// makes the check FAIL, never hang the run.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock(); private var opened = false
        func wait() async { for _ in 0..<500 where !isOpen { try? await Task.sleep(nanoseconds: 10_000_000) } }
        func open() { lock.lock(); opened = true; lock.unlock() }
        var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return opened }
    }
    /// Bounded: polls cond for about 3 s.
    private static func settle(_ cond: () -> Bool) async { for _ in 0..<300 where !cond() { try? await Task.sleep(nanoseconds: 10_000_000) } }
    private static func fixture(_ tag: String, _ files: [(String, Int)]) -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("spz-slc-\(tag)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for (name, size) in files { try! Data(repeating: 7, count: size).write(to: d.appendingPathComponent(name)) }
        return d
    }

    static func run() async {
        let names = ["skipped-list-load-runs-off-main-and-publishes-on-main", "skipped-list-cancel-suppresses-late-publish", "skipped-list-failed-read-shows-failed-never-empty"]
        let d = fixture("skipped-list", [("a.bin", 30_000)])
        defer { try? FileManager.default.removeItem(at: d) }
        guard let t = await ScanSession(root: d.path, excludes: [])?.run(progress: { _ in }) else {
            for n in names { Check.expect(n, false, "fixture") }; return
        }
        let two: [SkippedItem] = [SkippedItem(path: "/x/secret", reason: .permissionDenied, lossy: false),
                                  SkippedItem(path: "/x/bad\u{FFFD}name", reason: .unreadable, lossy: true)]

        // 1. load() returns while the read is still parked off-main (a synchronous read would park the caller here),
        // then publishes exactly what the reader answered once the gate opens.
        let g1 = Gate()
        let m1 = SkippedListModel(reader: { _ in await g1.wait(); return .success(two) })
        m1.load(tree: t)
        let returnedParked = !g1.isOpen && m1.items == nil && !m1.readFailed && m1.token == 1
        g1.open()
        await settle { m1.processedTokens.contains(1) }
        let published = m1.items == two && !m1.readFailed
        Check.expect("skipped-list-load-runs-off-main-and-publishes-on-main", returnedParked && published && m1.processedTokens.contains(1), "returnedParked=\(returnedParked) published=\(published)")

        // 2. cancel() while the read is parked: the late answer is processed but never published.
        let g2 = Gate()
        let m2 = SkippedListModel(reader: { _ in await g2.wait(); return .success(two) })
        m2.load(tree: t)
        let tok2 = m2.token
        m2.cancel()
        g2.open()
        await settle { m2.processedTokens.contains(tok2) }
        Check.expect("skipped-list-cancel-suppresses-late-publish", m2.processedTokens.contains(tok2) && m2.items == nil && !m2.readFailed, "processed=\(m2.processedTokens.contains(tok2)) items=\(m2.items == nil ? "nil" : "set") readFailed=\(m2.readFailed)")

        // 3. A failed read is a failed read, never an empty list.
        let m3 = SkippedListModel(reader: { _ in .failure(.invalid) })
        m3.load(tree: t)
        await settle { m3.processedTokens.contains(1) }
        Check.expect("skipped-list-failed-read-shows-failed-never-empty", m3.readFailed && m3.items == nil, "readFailed=\(m3.readFailed) items=\(m3.items == nil ? "nil" : "set")")
    }
}
#endif
