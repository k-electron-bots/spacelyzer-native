import SwiftUI

// UNCOMPILED and UNRUN until a Mac run. Read-only: nothing here touches the filesystem,
// the Trash, or the engine's tables. The skipped list is fixed when a scan ends, so a
// captured Tree shows one consistent list with no invalidation wiring.

/// Owns the one skipped-list read in flight. The read is OFF the main actor (one FFI
/// call per skipped entry; at 100k+ entries a synchronous read would stall the UI), the
/// publish is on the main actor, and a late result is shown only while its request token
/// is still current: cancel() or a newer load() makes the late answer a no-op.
@MainActor
final class SkippedListModel: ObservableObject {
    typealias Reader = @Sendable (Tree) async -> Result<[SkippedItem], EngineStatus>
    @Published private(set) var items: [SkippedItem]?
    @Published private(set) var readFailed = false
    private var task: Task<Void, Never>?
    /// Id of the latest load. Read-only outside; tests use it to wait for a specific load's processing.
    private(set) var token = 0
    #if SPZ_CI_TESTS
    /// TEST BUILDS ONLY. Tokens whose read has returned and been through the publish logic
    /// (published, dropped or superseded). Lets a check wait for a late read instead of sleeping.
    private(set) var processedTokens: Set<Int> = []
    #endif
    private let reader: Reader

    init(reader: @escaping Reader = { $0.skippedItemsChecked() }) {
        self.reader = reader
    }

    /// Starts the off-main read and returns immediately, so the view's ProgressView is
    /// live while the engine answers. Previous reads are superseded, never stacked.
    func load(tree: Tree) {
        task?.cancel()
        token += 1
        let mine = token
        items = nil; readFailed = false
        let reader = self.reader
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let result = await reader(tree)                // off-main: one FFI call per skipped entry
            await MainActor.run {
                guard let self else { return }
                #if SPZ_CI_TESTS
                self.processedTokens.insert(mine)
                #endif
                guard mine == self.token, !Task.isCancelled else { return }   // superseded or dismissed: never publish
                switch result {
                case .success(let list): self.items = list
                case .failure: self.readFailed = true
                }
            }
        }
    }

    /// Sheet dismissed. The in-flight read may still finish off-main (bounded work, harmless
    /// there); its result is never published after this.
    func cancel() {
        task?.cancel(); task = nil; token += 1
    }
}

/// Reviewable list of the locations a scan skipped, grouped by reason, from one tree.
/// Every count and entry comes from the status-checked engine reads; a failed read is
/// shown as a failed read, never as an empty or partial list.
struct SkippedListView: View {
    let tree: Tree
    @StateObject private var list: SkippedListModel

    init(tree: Tree, model: SkippedListModel? = nil) {
        self.tree = tree
        _list = StateObject(wrappedValue: model ?? SkippedListModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Not scanned").font(.headline)
            Text("These locations were not scanned, so they are not in the totals.")
                .font(.caption).foregroundStyle(.secondary)
            if list.readFailed {
                Text("The list could not be read from the engine. The scan itself is unchanged; rescan to try again.")
                    .font(.caption).foregroundStyle(.red)
            } else if let items = list.items {
                if items.isEmpty {
                    Text("Nothing was skipped.").font(.caption).foregroundStyle(.secondary)
                } else {
                    summary(itemCount: items.count)
                    // (path, reason) pairs are unique in the engine; a path alone can repeat
                    // across reasons, so identity is the list position, never the path text.
                    List(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.path).font(.caption).textSelection(.enabled)
                                .lineLimit(2).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(item.reason.label).font(.caption2).foregroundStyle(.orange)
                                if item.lossy {
                                    Text("Name shown approximately").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }.frame(minHeight: 120)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12).frame(width: 460, height: 340, alignment: .topLeading)
        .onAppear { list.load(tree: tree) }
        .onDisappear { list.cancel() }
    }

    @ViewBuilder private func summary(itemCount: Int) -> some View {
        switch tree.skippedCountsChecked() {
        case .success(let c):
            Text("\(itemCount) skipped: \(c.permissionDenied) not allowed, \(c.unreadable) unreadable, \(c.separateVolume) on another volume, \(c.userExcluded) excluded")
                .font(.caption).foregroundStyle(.secondary)
        case .failure(let e):
            Text("The per-reason counts could not be read (engine status \(e.rawValue)). The list below is complete on its own status-checked reads.")
                .font(.caption2).foregroundStyle(.orange)
        }
    }
}
