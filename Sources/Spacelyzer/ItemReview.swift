import CSpacelyzer
import SwiftUI

// UNCOMPILED and UNRUN until a Mac run. Mounted read-only behind Check on disk; not connected to Trash. Nothing here makes removal safe:
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
        var r = [UInt64](repeating: 0, count: 4)
        r.withUnsafeMutableBufferPointer { spz_review_layout($0.baseAddress) }
        var i = [UInt64](repeating: 0, count: 7)
        i.withUnsafeMutableBufferPointer { spz_inspect_layout($0.baseAddress) }
        let reviewOK = r[0] == UInt64(MemoryLayout<SpzReview>.size) && r[1] == UInt64(MemoryLayout<SpzReview>.alignment)
            && r[2] == UInt64(MemoryLayout<SpzReview>.offset(of: \.live_state) ?? 9999) && r[3] == UInt64(MemoryLayout<SpzReview>.offset(of: \.live) ?? 9999)
        // The nested SpzInspect: size, alignment and every field offset.
        let inspectOK = i[0] == UInt64(MemoryLayout<SpzInspect>.size) && i[1] == UInt64(MemoryLayout<SpzInspect>.alignment)
            && i[2] == UInt64(MemoryLayout<SpzInspect>.offset(of: \.mtime) ?? 9999) && i[3] == UInt64(MemoryLayout<SpzInspect>.offset(of: \.dev) ?? 9999)
            && i[4] == UInt64(MemoryLayout<SpzInspect>.offset(of: \.ino) ?? 9999) && i[5] == UInt64(MemoryLayout<SpzInspect>.offset(of: \.nlink) ?? 9999)
            && i[6] == UInt64(MemoryLayout<SpzInspect>.offset(of: \.kind) ?? 9999)
        return reviewOK && inspectOK
    }()

    /// Reads the filesystem OFF the main actor. Cancellation is checked before and after the FFI call; it does NOT interrupt a call already
    /// running inside the engine. Cancelling the calling task cancels the inner task too (a detached task does not
    /// inherit cancellation, so the handler forwards it) and the call then throws CancellationError. The result names its tree,
    /// node and table version; `ItemReviewModel` is the single place that decides whether it is still current.
    /// `version` is the table version the caller captured ONCE when it made the request; it is copied into the result unchanged.
    /// `parkForTest` runs inside the inner task before any read (a test hook that lets a test hold the read open and cancel it).
    static func review(tree: Tree, id: UInt32, version: UInt64, parkForTest: (@Sendable () async throws -> Void)? = nil) async throws -> ItemReviewResult {
        let treeID = ObjectIdentifier(tree)
        let work = Task.detached(priority: .userInitiated) { () throws -> ItemReviewResult in
            try Task.checkCancellation()
            if let park = parkForTest { try await park() }
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
            return ItemReviewResult(treeID: treeID, node: id, treeVersion: version, path: path, verdict: verdict, live: live)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

/// Owns the one review in flight. A new request or `invalidate()` cancels the old one. A result is shown only if its request token,
/// tree, node and the table version captured at request time ALL still match, and the tree's version has not moved since. A result that
/// arrives for the current request but is stale ends the in-progress state and sets `outdated`, so the UI never spins forever or shows old data.
/// The popover calls `invalidate()` when it disappears, and dismisses itself on selection, tree, filter or mutation changes.
@MainActor
final class ItemReviewModel: ObservableObject {
    typealias Reviewer = @Sendable (Tree, UInt32, UInt64) async throws -> ItemReviewResult
    @Published private(set) var result: ItemReviewResult?
    @Published private(set) var inProgress = false
    /// True when the answer for the current request was dropped as stale; the UI should ask the user to select the item again.
    @Published private(set) var outdated = false
    private var task: Task<Void, Never>?
    /// Id of the latest request. Read-only outside; tests use it to wait for a specific request's answer to be processed.
    private(set) var token = 0
    #if SPZ_CI_TESTS
    /// TEST BUILDS ONLY (compiled out of the shipping app, so nothing grows there). Tokens whose reviewer has returned and whose answer
    /// has been through the acceptance logic below (accepted, dropped or superseded). Lets a check wait for a late answer instead of sleeping.
    private(set) var processedTokens: Set<Int> = []
    #endif
    private var wanted: (tree: ObjectIdentifier, node: UInt32, version: UInt64)?
    private let reviewer: Reviewer
    /// Asked once before a read starts and once before an answer is accepted, so a caught engine panic (before or during the read) means no
    /// answer is shown as valid. Bounded and explicit: no polling. The app passes `!model.enginePoisoned`.
    private let trusted: @MainActor () -> Bool
    #if SPZ_CI_TESTS
    /// TEST BUILDS ONLY. Counts every request(), so a check can show that selection changes alone start no review.
    static var requestCountForTests = 0
    #endif

    init(trusted: @escaping @MainActor () -> Bool = { true },
         reviewer: @escaping Reviewer = { tree, id, version in try await ItemReview.review(tree: tree, id: id, version: version) }) {
        self.trusted = trusted; self.reviewer = reviewer
    }

    func request(tree: Tree, node: UInt32) {
        task?.cancel()
        #if SPZ_CI_TESTS
        Self.requestCountForTests += 1
        #endif
        token += 1
        let mine = token
        let version = tree.version                      // captured once; the result echoes it
        wanted = (ObjectIdentifier(tree), node, version)
        result = nil; outdated = false; inProgress = true
        if !trusted() { inProgress = false; outdated = true; return }                  // engine already reported an error: do not read, show nothing as valid
        let reviewer = self.reviewer
        task = Task { [weak self] in
            let r: ItemReviewResult?
            do { r = try await reviewer(tree, node, version) } catch { r = nil }       // cancelled or failed: nothing is shown for it
            #if SPZ_CI_TESTS
            defer { self?.processedTokens.insert(mine) }
            #endif
            guard let self, mine == self.token else { return }                          // superseded or invalidated: the newer owner decides the state
            defer { self.inProgress = false }
            guard self.trusted() else { self.result = nil; self.outdated = true; return }   // a panic was caught before or during the read
            guard let r, let w = self.wanted, r.treeID == w.tree, r.node == w.node, r.treeVersion == w.version, tree.version == w.version else {
                self.result = nil; self.outdated = true; return
            }
            if r.verdict.isUnexpected { Perf.log("item-review unexpected engine code for node \(node)") }   // main actor only
            self.result = r
        }
    }

    /// Selection cleared, tree replaced or filter changed: forget the result and cancel any read.
    func invalidate() {
        task?.cancel(); token += 1; wanted = nil; result = nil; inProgress = false; outdated = false
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

/// Read-only popover opened by an explicit click on "Check on disk". It does no I/O until it appears, and it never reaches Trash.
/// It is dismissed (by its owner) when the selection or the tree changes, and it cancels its read when it disappears.
/// UNCOMPILED/UNRUN until a Mac build.
struct ItemReviewPopover: View {
    /// Passed explicitly, not read from the environment: nothing here assumes a popover inherits the window's environment.
    let model: AppModel
    let tree: Tree
    let id: UInt32
    let dismiss: () -> Void
    @StateObject private var review: ItemReviewModel
    init(model: AppModel, tree: Tree, id: UInt32, dismiss: @escaping () -> Void) {
        self.model = model; self.tree = tree; self.id = id; self.dismiss = dismiss
        _review = StateObject(wrappedValue: ItemReviewModel(trusted: { [weak model] in model.map { !$0.enginePoisoned } ?? false }))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let r = review.result {
                ItemDetailsView(result: r)
                Button("Preview") { QuickLookController.show(path: r.path) }
                    .controlSize(.small)
                    .accessibilityLabel("Preview the item as it is on disk now")
            } else if review.outdated {
                Text("The results changed while this was being checked. Close this and check again.").font(.caption).foregroundStyle(.orange)
            } else if review.inProgress {
                ProgressView("Checking…").controlSize(.small)
            }
            Text("Read only. This compares the item on disk with what the scan recorded at this moment. It does not make a later removal safe.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12).frame(width: 360, alignment: .leading)
        .onAppear { review.request(tree: tree, node: id) }
        .onDisappear { review.invalidate() }
        .onChange(of: model.revision) { _, _ in review.invalidate(); dismiss() }       // tree changed or replaced
        .onChange(of: model.selected) { _, _ in review.invalidate(); dismiss() }       // selection moved
        .onChange(of: model.filterRevision) { _, _ in review.invalidate(); dismiss() } // filter result changed
        .onChange(of: model.poisoned) { _, p in if p { review.invalidate(); dismiss() } }   // stored flag set by markPoisoned; the pre/post trusted() checks cover a panic that is not yet published
        .onChange(of: model.mutationPending) { _, p in if p { review.invalidate(); dismiss() } }  // a removal is being applied
    }
}
