import CSpacelyzer
import SwiftUI

// UNCOMPILED and UNRUN until a Mac run. Not mounted anywhere and not connected to Trash. Nothing here makes removal safe:
// it shows what is on disk NOW and refuses to describe an item as "the same" unless the engine says so.

/// What the identity check said about one item. The raw engine code is kept for logs and tests.
enum IdentityVerdict: Sendable, Equatable {
    case same                       // 0
    case replaced                   // 1: live (dev, ino) or kind differs from the scan
    case noScannedIdentity          // 2
    case unaddressableName          // 3: the scanned name had non-UTF-8 bytes
    case ancestorIsSymlink          // 4
    case gone                       // 5
    case unreadable(errno: Int32)   // code <= -1000: the OS refused or failed (errno = -(code + 1000))
    case engineFault(code: Int32)   // -1, -2, -3, or any code this app does not know: never read as .same

    init(engineCode c: Int32) {
        switch c {
        case 0: self = .same
        case 1: self = .replaced
        case 2: self = .noScannedIdentity
        case 3: self = .unaddressableName
        case 4: self = .ancestorIsSymlink
        case 5: self = .gone
        case ...(-1000): self = .unreadable(errno: -(c + 1000))
        default: self = .engineFault(code: c)
        }
    }

    var allowsProceeding: Bool { self == .same }

    /// Always shown to the user when the verdict is not .same. Plain words; when it is .same it promises nothing about the future.
    var message: String {
        switch self {
        case .same: return "Matches the scan at the moment of checking. It can still change before an action."
        case .replaced: return "This item was replaced since the scan, so it is not the item you reviewed. Nothing was changed. Rescan to see what is there now."
        case .noScannedIdentity: return "The scan did not record an identity for this item, so it cannot be confirmed. Nothing was changed. Rescan and try again."
        case .unaddressableName: return "This item's name contains characters the scan could not keep exactly, so it cannot be confirmed. Nothing was changed. Use Finder for this one."
        case .ancestorIsSymlink: return "A folder above this item became a link since the scan, so the path may point somewhere else now. Nothing was changed. Rescan to refresh."
        case .gone: return "This item is no longer at its scanned location. Nothing was changed. Rescan to refresh."
        case .unreadable(let e):
            let reason = e == 13 || e == 1 ? "macOS did not allow Spacelyzer to look at it" : "macOS could not read it"
            return "\(reason) (system error \(e)). Nothing was changed. Check Full Disk Access or rescan."
        case .engineFault(let c):
            return "The item could not be checked because the engine gave an unexpected answer. Nothing was changed. Rescan and try again. (Reference: engine code \(c).)"
        }
    }

    /// True for answers this app did not expect, so the caller can log them.
    var isUnexpected: Bool { if case .engineFault = self { return true }; return false }
}

/// Live facts from the SAME lstat that produced the verdict. Present only when the leaf was observed.
struct ItemReviewResult: Sendable, Equatable {
    /// Which request this answers. A consumer must compare ALL of these with the current selection before showing it.
    var treeID: ObjectIdentifier
    var node: UInt32
    var treeVersion: UInt64
    var path: String
    var verdict: IdentityVerdict
    var live: Live?
    struct Live: Sendable, Equatable {
        /// .scannedItem: describes the item the scan recorded. .differentItem: describes another item now at this path; label it that way.
        var describes: Describes
        var allocated: UInt64
        var logical: UInt64
        var modified: Date
        var hardLinks: UInt32
        var kind: Kind
        enum Describes: Sendable { case scannedItem, differentItem }
        enum Kind: Sendable { case file, folder, symlink, other }
    }
}

enum ItemReview {
    /// The imported C layout must equal Rust's, or the answer is refused. Checked once.
    private static let layoutOK: Bool = {
        var v = [UInt64](repeating: 0, count: 3)
        v.withUnsafeMutableBufferPointer { spz_review_layout($0.baseAddress) }
        return v[0] == UInt64(MemoryLayout<SpzReview>.size) && v[1] == UInt64(MemoryLayout<SpzReview>.alignment)
            && v[2] == UInt64(MemoryLayout<SpzReview>.offset(of: \.live_state) ?? 9999)
    }()

    /// Reads the filesystem OFF the main actor. Cancelling the calling task cancels the inner task too (a detached task does not
    /// inherit cancellation, so the handler forwards it) and the call then throws CancellationError. The result names its tree,
    /// node and table version; `ItemReviewModel` is the single place that decides whether it is still current.
    static func review(tree: Tree, id: UInt32) async throws -> ItemReviewResult {
        let treeID = ObjectIdentifier(tree)
        let version = tree.version
        let work = Task.detached(priority: .userInitiated) { () throws -> ItemReviewResult in
            try Task.checkCancellation()
            let path = tree.path(id)
            // tree.path returns "" for a stale id from an older tree; an empty path is never inspected.
            guard !path.isEmpty, layoutOK else {
                return ItemReviewResult(treeID: treeID, node: id, treeVersion: version, path: path, verdict: .engineFault(code: -1), live: nil)
            }
            var raw = SpzReview()
            let code = spz_tree_review(tree.ptr, id, &raw)
            try Task.checkCancellation()
            var live: ItemReviewResult.Live? = nil
            if code >= 0 && raw.live_state != 0 {
                let kind: ItemReviewResult.Live.Kind
                switch raw.live.kind { case 0: kind = .file; case 1: kind = .folder; case 2: kind = .symlink; default: kind = .other }
                live = ItemReviewResult.Live(describes: raw.live_state == 1 ? .scannedItem : .differentItem,
                                             allocated: raw.live.allocated, logical: raw.live.logical,
                                             modified: Date(timeIntervalSince1970: TimeInterval(raw.live.mtime)),
                                             hardLinks: raw.live.nlink, kind: kind)
            }
            let verdict = IdentityVerdict(engineCode: code)
            if verdict.isUnexpected { Perf.log("item-review unexpected engine code \(code) for node \(id)") }
            return ItemReviewResult(treeID: treeID, node: id, treeVersion: version, path: path, verdict: verdict, live: live)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

/// Owns the one review in flight. A new request or `invalidate()` cancels the old one, and a late result is dropped unless its tree,
/// node and request token all still match. This is the only place a result is accepted.
@MainActor
final class ItemReviewModel: ObservableObject {
    @Published private(set) var result: ItemReviewResult?
    @Published private(set) var inProgress = false
    private var task: Task<Void, Never>?
    private var token = 0
    private var wanted: (tree: ObjectIdentifier, node: UInt32)?

    func request(tree: Tree, node: UInt32) {
        task?.cancel()
        token += 1
        let mine = token
        wanted = (ObjectIdentifier(tree), node)
        result = nil
        inProgress = true
        task = Task { [weak self] in
            let r: ItemReviewResult?
            do { r = try await ItemReview.review(tree: tree, id: node) } catch { r = nil }   // cancelled: nothing is shown for it
            guard let self, mine == self.token, let r, let w = self.wanted, r.treeID == w.tree, r.node == w.node, r.treeVersion == tree.version else { return }   // a version change since the request means the answer is stale: dropped
            self.result = r
            self.inProgress = false
        }
    }

    /// Selection cleared, tree replaced or filter changed: forget the result and cancel any read.
    func invalidate() {
        task?.cancel(); token += 1; wanted = nil; result = nil; inProgress = false
    }
}

/// Read-only details for one reviewed item. Takes a finished result; does no I/O itself.
struct ItemDetailsView: View {
    let result: ItemReviewResult
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.path).font(.callout).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
            if let live = result.live {
                if live.describes == .differentItem {
                    Text("Now at this path (a different item than the scan recorded):").font(.caption.bold()).foregroundStyle(.red)
                }
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
