#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import Foundation

// UNCOMPILED and UNRUN until a Mac run. Checks for the read-only Quick Look preview seam
// (E4d): absolute paths are presented exactly as given; relative and empty paths are refused
// before the panel is touched; a second preview replaces the first; presentation is
// synchronous. The panel seam is substituted throughout, so no real panel or file is touched.
// Real QLPreviewPanel behavior is Mac-unverified.
enum QuickLookChecks {
    static func run() {
        var seen: [URL] = []
        let saved = QuickLookController.present
        QuickLookController.present = { seen.append($0) }
        defer { QuickLookController.present = saved }

        // 1. An absolute path reaches the panel seam as exactly that file URL, and show accepts.
        let okAbs = QuickLookController.show(path: "/tmp/spz-ql-fixture.bin")
        Check.expect("quicklook-absolute-path-presented-exactly", okAbs && seen == [URL(fileURLWithPath: "/tmp/spz-ql-fixture.bin")], "ok=\(okAbs) seen=\(seen)")

        // 2-3. Relative and empty paths are refused before the panel seam is reached.
        seen.removeAll()
        let relRefused = !QuickLookController.show(path: "tmp/relative.bin")
        Check.expect("quicklook-relative-path-refused-before-panel", relRefused && seen.isEmpty, "refused=\(relRefused) seen=\(seen)")
        let emptyRefused = !QuickLookController.show(path: "")
        Check.expect("quicklook-empty-path-refused-before-panel", emptyRefused && seen.isEmpty, "refused=\(emptyRefused) seen=\(seen)")

        // 4. A second preview replaces the first: one shared panel, the latest URL wins.
        seen.removeAll()
        _ = QuickLookController.show(path: "/tmp/spz-ql-a.bin")
        _ = QuickLookController.show(path: "/tmp/spz-ql-b.bin")
        Check.expect("quicklook-second-preview-replaces-first", seen == [URL(fileURLWithPath: "/tmp/spz-ql-a.bin"), URL(fileURLWithPath: "/tmp/spz-ql-b.bin")], "seen=\(seen)")

        // 5. Presentation is synchronous: the seam has run before show returns, so a caller on
        // the main actor never hands the panel a stale item after a later state change.
        var hit = false
        QuickLookController.present = { _ in hit = true }
        _ = QuickLookController.show(path: "/tmp/spz-ql-c.bin")
        Check.expect("quicklook-present-synchronous-before-return", hit, "hit=\(hit)")
    }
}
#endif
