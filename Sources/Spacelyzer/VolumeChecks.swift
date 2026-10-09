#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import Foundation

// UNCOMPILED and UNRUN until a Mac run. Regression checks for the volume header: a real
// statvfs read satisfies the raw-number invariants; the header's read runs off the main
// actor and publishes on it; a failed read is a failed read, never a guessed number; a
// repeat load for the same path does not re-read under a published result. Bounded gates,
// no sleeps. The reader is injected for the publish/failure checks (path-based, no tree).
@MainActor
enum VolumeChecks {
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

    static func run() async {
        // 1. A real read of the temp directory's volume: success and the raw statvfs
        // invariants (positive total, free within total, available within free).
        let real = await Task.detached(priority: .utility) {
            volumeInfoChecked(path: FileManager.default.temporaryDirectory.path)
        }.value
        let invariants: Bool
        switch real {
        case .success(let v): invariants = v.totalBytes > 0 && v.freeBytes <= v.totalBytes && v.availableBytes <= v.freeBytes && !v.saturated
        case .failure: invariants = false
        }
        Check.expect("volume-info-real-read-satisfies-statvfs-invariants", invariants, "result=\(real)")

        // 2. load() returns while the reader is parked off-main, then publishes on main.
        let v1 = VolumeInfo(totalBytes: 100, freeBytes: 40, availableBytes: 30, readOnly: false, saturated: false)
        let g1 = Gate()
        let m1 = VolumeHeaderModel(reader: { _ in await g1.wait(); return .success(v1) })
        m1.load(path: "/x")
        let returnedParked = !g1.isOpen && m1.info == nil && m1.failure == nil && m1.token == 1
        g1.open()
        await settle { m1.processedTokens.contains(1) }
        let published = m1.info == v1 && m1.failure == nil
        Check.expect("volume-header-load-off-main-publishes-on-main", returnedParked && published && m1.processedTokens.contains(1), "returnedParked=\(returnedParked) published=\(published)")

        // 3. A failed read is a failed read, never a number.
        let m2 = VolumeHeaderModel(reader: { _ in .failure(.osError(2)) })
        m2.load(path: "/x")
        await settle { m2.processedTokens.contains(1) }
        Check.expect("volume-header-failed-read-shows-failed-never-number", m2.failure == .osError(2) && m2.info == nil, "failure=\(String(describing: m2.failure)) info=\(m2.info == nil ? "nil" : "set")")

        // 4. A repeat load for the same path does not re-read under a published result.
        let tok = m1.token
        m1.load(path: "/x")
        Check.expect("volume-header-repeat-load-same-path-does-not-reread", m1.token == tok && m1.info == v1, "token=\(m1.token) was \(tok)")
    }
}
#endif
