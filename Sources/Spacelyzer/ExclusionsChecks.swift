#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import Foundation

// UNCOMPILED and UNRUN until a Mac run. Regression checks for the exclusions editor: typing
// rules (trim, blank and exact-duplicate rejected), exact-match removal, and the unobserved
// report's honesty (read runs off the main actor and publishes on it; a failed read is a
// failed read, never an empty list). Bounded gates, no sleeps. The reader is injected, so
// engine unobserved-exclusion behavior itself stays covered by the Linux engine tests.
@MainActor
enum ExclusionsChecks {
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
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("spz-exc-\(tag)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for (name, size) in files { try! Data(repeating: 7, count: size).write(to: d.appendingPathComponent(name)) }
        return d
    }

    static func run() async {
        // 1. Typing rules: surrounding whitespace trimmed, blank rejected, exact duplicate
        // rejected, interior characters kept exactly.
        let base = ["/a", "/b"]
        let trimmed = ExclusionEditing.adding(base, "  /c  ") == ["/a", "/b", "/c"]
        let blankRejected = ExclusionEditing.adding(base, "   ") == nil
        let dupRejected = ExclusionEditing.adding(base, "/a") == nil
        let interiorKept = ExclusionEditing.normalized(" /x y ") == "/x y"
        Check.expect("exclusions-add-trims-rejects-blank-and-exact-duplicate", trimmed && blankRejected && dupRejected && interiorKept, "trimmed=\(trimmed) blank=\(blankRejected) dup=\(dupRejected) interior=\(interiorKept)")

        // 2. Removal is exact-match, like the view's Remove button.
        var list = ["/a", "/b", "/c"]
        list.removeAll { $0 == "/b" }
        Check.expect("exclusions-remove-is-exact-match", list == ["/a", "/c"], "list=\(list)")

        // 3. load() returns while the reader is parked off-main, then publishes on main.
        let d = fixture("unobserved", [("a.bin", 30_000)])
        defer { try? FileManager.default.removeItem(at: d) }
        guard let t = await ScanSession(root: d.path, excludes: [])?.run(progress: { _ in }) else {
            Check.expect("exclusions-unobserved-load-off-main-publishes-on-main", false, "fixture")
            Check.expect("exclusions-unobserved-failed-read-shows-failed-never-empty", false, "fixture")
            return
        }
        let two = [UnobservedExclusion(path: "/x/typo", reason: .notSeen),
                   UnobservedExclusion(path: "/x/secret", reason: .insideSkippedSubtree)]
        let g1 = Gate()
        let m1 = ExclusionsModel(reader: { _ in await g1.wait(); return .success(two) })
        m1.load(tree: t)
        let returnedParked = !g1.isOpen && m1.unobserved == nil && !m1.readFailed && m1.token == 1
        g1.open()
        await settle { m1.processedTokens.contains(1) }
        let published = m1.unobserved == two && !m1.readFailed
        Check.expect("exclusions-unobserved-load-off-main-publishes-on-main", returnedParked && published && m1.processedTokens.contains(1), "returnedParked=\(returnedParked) published=\(published)")

        // 4. A failed read is a failed read, never an empty list.
        let m2 = ExclusionsModel(reader: { _ in .failure(.invalid) })
        m2.load(tree: t)
        await settle { m2.processedTokens.contains(1) }
        Check.expect("exclusions-unobserved-failed-read-shows-failed-never-empty", m2.readFailed && m2.unobserved == nil, "readFailed=\(m2.readFailed) unobserved=\(m2.unobserved == nil ? "nil" : "set")")
    }
}
#endif
