#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import Foundation

// UNCOMPILED and UNRUN until a Mac run. Mount checks for the read-only identity review:
// "Check on disk" opens only for a real node of a live tree, never for the root, an out-of-range
// id or no tree at all, and proposing a review starts NO read by itself (the popover starts one
// when it appears). Deterministic: no sleeps; the tree is the scanner's own fixture tree. The
// review read and its staleness/cancellation rules are covered by reviewModelChecks (SpacelyzerApp).
@MainActor
enum ItemReviewChecks {
    static func run() async {
        let names = ["item-review-propose-opens-for-real-node", "item-review-propose-refuses-non-node-and-empty-tree", "item-review-propose-starts-no-read"]
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("spz-irc-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try! Data(repeating: 3, count: 10_000).write(to: d.appendingPathComponent("a.bin"))
        defer { try? FileManager.default.removeItem(at: d) }
        guard let t = await ScanSession(root: d.path, excludes: [])?.run(progress: { _ in }) else {
            for n in names { Check.expect(n, false, "fixture") }; return
        }
        guard let victim = t.find(path: "\(d.path)/a.bin") else {
            for n in names { Check.expect(n, false, "fixture find") }; return
        }

        // 1. A real node of a live tree opens the review.
        let m1 = AppModel()
        m1.tree = t
        m1.proposeReview(of: victim)
        Check.expect("item-review-propose-opens-for-real-node", m1.reviewItem == victim, "reviewItem=\(String(describing: m1.reviewItem))")

        // 2. The root (0), an out-of-range id and no tree at all are all refused: nothing opens.
        let m2 = AppModel()
        m2.tree = t
        m2.proposeReview(of: 0)
        let rootRefused = m2.reviewItem == nil
        m2.proposeReview(of: UInt32(t.nodeCount) + 5)
        let rangeRefused = m2.reviewItem == nil
        let m3 = AppModel()
        m3.proposeReview(of: victim)
        Check.expect("item-review-propose-refuses-non-node-and-empty-tree", rootRefused && rangeRefused && m3.reviewItem == nil, "root=\(rootRefused) range=\(rangeRefused) noTree=\(m3.reviewItem == nil)")

        // 3. Proposing a review starts no read by itself: the request counter only moves when a popover appears.
        let before = ItemReviewModel.requestCountForTests
        let m4 = AppModel()
        m4.tree = t
        m4.proposeReview(of: victim)
        Check.expect("item-review-propose-starts-no-read", m4.reviewItem == victim && ItemReviewModel.requestCountForTests == before, "requests=\(ItemReviewModel.requestCountForTests - before)")
    }
}
#endif
