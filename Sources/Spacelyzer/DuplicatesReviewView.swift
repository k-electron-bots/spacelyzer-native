import SwiftUI

// UNCOMPILED and UNRUN until a Mac run. Read-only review of one duplicate-finder pass:
// nothing here touches the filesystem, the Trash, or the engine's tables. Caps are
// report-only (a capped report is not "all duplicates" and must never drive removal) and
// sizes are ALLOCATED bytes, not reclaimable space.

/// Owns the one duplicate pass in flight. The pass reads file contents and BLOCKS its
/// thread (minutes on a large tree), so it runs OFF the main actor behind a
/// DupScanControl: Task cancellation alone would leave the pass running, so cancel() sets
/// the engine's sticky flag and the pass returns early with its cancelled flag. The
/// publish is on the main actor; a late answer is shown only while its request token is
/// still current.
@MainActor
final class DuplicatesModel: ObservableObject {
    typealias Reader = @Sendable (Tree, DupScanControl) async -> Result<DupFindResult, EngineStatus>
    @Published private(set) var result: DupFindResult?
    @Published private(set) var readFailed = false
    @Published private(set) var cancelled = false
    @Published private(set) var progress = SpzDupProgress()
    private var task: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    private var control: DupScanControl?
    /// Id of the latest load. Read-only outside; tests use it to wait for a specific load's processing.
    private(set) var token = 0
    #if SPZ_CI_TESTS
    /// TEST BUILDS ONLY. Tokens whose read has returned and been through the publish logic.
    private(set) var processedTokens: Set<Int> = []
    #endif
    private let reader: Reader

    init(reader: @escaping Reader = { t, c in t.duplicatesChecked(minSize: 1, maxGroups: 200, maxMembers: 100, control: c) }) {
        self.reader = reader
    }

    /// Starts the pass off-main and returns immediately, so the view's progress line is
    /// live while the engine answers. A previous pass is cancelled through its control
    /// (its own thread frees the control when the pass returns) and superseded, never stacked.
    func load(tree: Tree) {
        task?.cancel(); poller?.cancel()
        control?.cancel()                       // sticky: a running old pass returns early and frees its control
        token += 1
        let mine = token
        result = nil; readFailed = false; cancelled = false
        progress = SpzDupProgress()
        let ctl = DupScanControl()
        control = ctl
        let reader = self.reader
        poller = Task { [weak self, ctl] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self, mine == self.token else { return }
                self.progress = ctl.progress()  // instant atomic read; main actor is fine
            }
        }
        task = Task.detached(priority: .userInitiated) { [weak self, ctl] in
            let result = await reader(tree, ctl)            // off-main: blocking pass
            await MainActor.run {
                guard let self else { return }
                #if SPZ_CI_TESTS
                self.processedTokens.insert(mine)
                #endif
                self.poller?.cancel()
                guard mine == self.token, !Task.isCancelled else { return }   // superseded or dismissed: never publish
                switch result {
                case .success(let r) where r.summary.cancelled: self.cancelled = true   // a cancelled pass is never partial numbers
                case .success(let r): self.result = r
                case .failure: self.readFailed = true
                }
            }
        }
    }

    /// Sheet dismissed. The pass is asked to stop through its control; its late answer is
    /// processed but never published.
    func cancel() {
        control?.cancel(); control = nil
        task?.cancel(); task = nil
        poller?.cancel(); poller = nil
        token += 1
    }
}

/// Read-only duplicate review for one captured tree. Every number comes from one
/// status-checked report: a failed read is a failed read, a cancelled pass is cancelled,
/// a capped report is labeled partial - none is ever shown as "all duplicates".
struct DuplicatesReviewView: View {
    let tree: Tree
    @StateObject private var model: DuplicatesModel

    init(tree: Tree, model: DuplicatesModel? = nil) {
        self.tree = tree
        _model = StateObject(wrappedValue: model ?? DuplicatesModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Duplicates").font(.headline)
            Text("Same content in more than one copy. Allocated bytes are not reclaimable space. Copies stored with different allocation (sparse, compressed, some clones) can be missed - a recall limit, never a false duplicate.")
                .font(.caption).foregroundStyle(.secondary)
            if model.readFailed {
                Text("The duplicates could not be read from the engine. The scan itself is unchanged; rescan to try again.")
                    .font(.caption).foregroundStyle(.red)
            } else if model.cancelled {
                Text("The read was cancelled before it finished, so there is no answer to show.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let r = model.result {
                if r.groups.isEmpty {
                    Text("No duplicate files found.").font(.caption).foregroundStyle(.secondary)
                    if r.summary.partial { partialNote }
                } else {
                    summary(r)
                    groupsList(r)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    if model.progress.candidates > 0 {
                        Text("Examined \(model.progress.examined.formatted()) of \(model.progress.candidates.formatted()) candidates")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12).frame(width: 520, height: 420, alignment: .topLeading)
        .onAppear { model.load(tree: tree) }
        .onDisappear { model.cancel() }
    }

    private var partialNote: some View {
        Text("Partial: the read hit a cap before every group was found, so this is not all duplicates.")
            .font(.caption2).foregroundStyle(.orange)
    }

    @ViewBuilder private func summary(_ r: DupFindResult) -> some View {
        Text("\(r.summary.groupsListed) groups · \(formatBytes(r.summary.duplicateAllocatedBytes)) allocated in duplicates")
            .font(.caption)
        if r.summary.partial { partialNote }
        if r.summary.unreadable > 0 || r.summary.changed > 0 {
            Text("\(r.summary.unreadable) unreadable · \(r.summary.changed) changed while reading")
                .font(.caption2).foregroundStyle(.secondary)
        }
        if r.summary.hardlinkAliases > 0 {
            Text("\(r.summary.hardlinkAliases) hard-linked: those copies share one inode, removing one frees nothing")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// One row per group: a bar sized against the largest group, then the member paths.
    private func groupsList(_ r: DupFindResult) -> some View {
        let maxBytes = max(r.groups.map(\.size).max() ?? 1, 1)
        return List(Array(r.groups.enumerated()), id: \.offset) { _, g in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(width: max(24, 180 * CGFloat(g.size) / CGFloat(maxBytes)), height: 8)
                    Text("\(g.memberCount) copies × \(formatBytes(g.size))").font(.caption)
                    if g.linked { Text("hard-linked").font(.caption2).foregroundStyle(.orange) }
                }
                ForEach(Array(g.paths.enumerated()), id: \.offset) { _, p in
                    Text(p).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                if g.listingCapped {
                    Text("+\(g.memberCount - g.paths.count) more not listed").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.frame(minHeight: 160)
    }
}
