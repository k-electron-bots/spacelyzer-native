import CSpacelyzer
import SwiftUI

// UNCOMPILED and UNRUN until a Mac run. Not mounted anywhere and not connected to Trash. Nothing here makes removal safe:
// it shows what is on disk NOW and refuses to describe an item as "the same" unless the engine says so.

/// What the identity check said about one item. The raw engine code is kept so a test or log can show it.
enum IdentityVerdict: Sendable, Equatable {
    case same                       // 0
    case replaced                   // 1: live (dev, ino) or kind differs from the scan
    case noScannedIdentity          // 2
    case unaddressableName          // 3: the scanned name had non-UTF-8 bytes
    case ancestorIsSymlink          // 4
    case gone                       // 5
    case failed(code: Int32)        // negative engine code, see spacelyzer.h

    init(engineCode c: Int32) {
        switch c {
        case 0: self = .same
        case 1: self = .replaced
        case 2: self = .noScannedIdentity
        case 3: self = .unaddressableName
        case 4: self = .ancestorIsSymlink
        case 5: self = .gone
        default: self = .failed(code: c)    // includes any code this app does not know: never read as .same
        }
    }

    var allowsProceeding: Bool { self == .same }

    /// Always shown to the user when the verdict is not .same. Plain words, no promise of safety when it is .same.
    var message: String {
        switch self {
        case .same: return "Matches the scan at the moment of checking. It can still change before an action."
        case .replaced: return "This item was replaced since the scan, so it is not the item you reviewed. Nothing was changed. Rescan to see what is there now."
        case .noScannedIdentity: return "The scan did not record an identity for this item, so it cannot be confirmed. Nothing was changed. Rescan and try again."
        case .unaddressableName: return "This item's name contains characters the scan could not keep exactly, so it cannot be confirmed. Nothing was changed. Use Finder for this one."
        case .ancestorIsSymlink: return "A folder above this item became a link since the scan, so the path may point somewhere else now. Nothing was changed. Rescan to refresh."
        case .gone: return "This item is no longer at its scanned location. Nothing was changed. Rescan to refresh."
        case .failed(let code): return "The item could not be checked (code \(code)). Nothing was changed. Rescan and try again."
        }
    }
}

/// Live facts from lstat plus the verdict. All values are plain and Sendable so they can cross from a background task.
struct ItemReviewResult: Sendable, Equatable {
    var path: String
    var verdict: IdentityVerdict
    /// nil when the live inspect failed (gone, no permission, etc.); `inspectCode` then holds the engine return code.
    var live: Live?
    var inspectCode: Int32
    struct Live: Sendable, Equatable {
        var allocated: UInt64
        var logical: UInt64
        var modified: Date
        var hardLinks: UInt32
        var kind: Kind
        enum Kind: Sendable { case file, folder, symlink, other }
    }
}

enum ItemReview {
    /// Reads the filesystem OFF the main actor and returns Sendable values. Cooperative cancellation is honoured before any
    /// value is returned, so a result for a selection that has since changed is dropped by the caller instead of shown.
    /// The caller must compare `tree` and `id` with the current selection before using the result.
    static func review(tree: Tree, id: UInt32) async throws -> ItemReviewResult {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let path = tree.path(id)
            // Bounds-checked: tree.path returns "" for a stale id from an older tree. An empty path is never inspected.
            guard !path.isEmpty else { return ItemReviewResult(path: "", verdict: .failed(code: -1), live: nil, inspectCode: -1) }
            let verdict = IdentityVerdict(engineCode: spz_tree_check_identity(tree.ptr, id))
            var raw = SpzInspect()
            let rc = spz_inspect_path(path, &raw)
            try Task.checkCancellation()
            guard rc == 0 else { return ItemReviewResult(path: path, verdict: verdict, live: nil, inspectCode: rc) }
            let kind: ItemReviewResult.Live.Kind
            switch raw.kind { case 0: kind = .file; case 1: kind = .folder; case 2: kind = .symlink; default: kind = .other }
            let live = ItemReviewResult.Live(allocated: raw.allocated, logical: raw.logical, modified: Date(timeIntervalSince1970: TimeInterval(raw.mtime)),
                                             hardLinks: raw.nlink, kind: kind)
            return ItemReviewResult(path: path, verdict: verdict, live: live, inspectCode: 0)
        }.value
    }
}

/// Read-only details for one reviewed item. Takes a finished result; does no I/O itself.
struct ItemDetailsView: View {
    let result: ItemReviewResult
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.path).font(.callout).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
            if let live = result.live {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    GridRow { Text("On disk").foregroundStyle(.secondary); Text(formatBytes(live.allocated)) }
                    GridRow { Text("Length").foregroundStyle(.secondary); Text(formatBytes(live.logical)) }
                    GridRow { Text("Modified").foregroundStyle(.secondary); Text(live.modified.formatted(date: .abbreviated, time: .shortened)) }
                    if live.hardLinks > 1 { GridRow { Text("Hard links").foregroundStyle(.secondary); Text("\(live.hardLinks): other names share this data, so removing one name may free no space") } }
                }.font(.caption)
            }
            Text(result.verdict.message)
                .font(.caption).foregroundStyle(result.verdict.allowsProceeding ? Color.secondary : Color.red)
                .accessibilityLabel(result.verdict.allowsProceeding ? "Matches the scan when checked" : "Cannot confirm this item. \(result.verdict.message)")
        }
    }
}
