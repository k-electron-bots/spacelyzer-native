import SwiftUI

// UNCOMPILED and UNRUN until a Mac run. Edits the app's exclusion list only: the list is
// handed to the engine when a scan starts, so changes apply when you rescan and the numbers
// on screen never change from editing here. Nothing here touches the filesystem, the Trash,
// or the engine's tables.

/// Normalization for one typed-in exclusion. Pure so the checks can exercise it without UI.
enum ExclusionEditing {
    /// The path to add, or nil when the draft is blank. Trims surrounding whitespace; the
    /// interior is kept exactly as typed (the engine matches exact path strings).
    static func normalized(_ draft: String) -> String? {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    /// The list with the draft appended, or nil when the draft is blank or already present
    /// (exact match, because the engine's matching is exact-string).
    static func adding(_ list: [String], _ draft: String) -> [String]? {
        guard let t = normalized(draft), !list.contains(t) else { return nil }
        return list + [t]
    }
}

/// Owns the one unobserved-exclusion read in flight. The read is off the main actor and the
/// publish is on it: the list is bounded by the user's exclusion count, but no engine list
/// ever reads synchronously on main in this app. A late answer is shown only while its
/// request token is still current.
@MainActor
final class ExclusionsModel: ObservableObject {
    typealias Reader = @Sendable (Tree) async -> Result<[UnobservedExclusion], EngineStatus>
    @Published private(set) var unobserved: [UnobservedExclusion]?
    @Published private(set) var readFailed = false
    private var task: Task<Void, Never>?
    /// Id of the latest load. Read-only outside; tests use it to wait for a specific load's processing.
    private(set) var token = 0
    #if SPZ_CI_TESTS
    /// TEST BUILDS ONLY. Tokens whose read has returned and been through the publish logic.
    private(set) var processedTokens: Set<Int> = []
    #endif
    private let reader: Reader

    init(reader: @escaping Reader = { $0.unobservedExclusionsChecked() }) {
        self.reader = reader
    }

    /// Starts the off-main read and returns immediately, so the view's ProgressView is live
    /// while the engine answers. Previous reads are superseded, never stacked.
    func load(tree: Tree) {
        task?.cancel()
        token += 1
        let mine = token
        unobserved = nil; readFailed = false
        let reader = self.reader
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let result = await reader(tree)
            await MainActor.run {
                guard let self else { return }
                #if SPZ_CI_TESTS
                self.processedTokens.insert(mine)
                #endif
                guard mine == self.token, !Task.isCancelled else { return }   // superseded or dismissed: never publish
                switch result {
                case .success(let list): self.unobserved = list
                case .failure: self.readFailed = true
                }
            }
        }
    }

    /// Sheet dismissed. A late result is never published after this.
    func cancel() {
        task?.cancel(); task = nil; token += 1
    }
}

/// Editor for the paths a scan skips at your request, plus the engine's report of requested
/// exclusions the walk never observed. Unobserved is NOT proof a path is absent; the view
/// says so next to the report.
struct ExclusionsView: View {
    @Binding var exclusions: [String]
    let tree: Tree?
    @StateObject private var model: ExclusionsModel
    @State private var draft = ""
    @Environment(\.dismiss) private var dismiss

    init(exclusions: Binding<[String]>, tree: Tree?, model: ExclusionsModel? = nil) {
        _exclusions = exclusions
        self.tree = tree
        _model = StateObject(wrappedValue: model ?? ExclusionsModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exclusions").font(.headline)
            Text("Scans skip these locations. Changes apply when you rescan; the numbers on screen do not change from editing here.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Path to skip, e.g. /Users/you/Videos", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(ExclusionEditing.normalized(draft) == nil)
            }
            if exclusions.isEmpty {
                Text("No exclusions. Every location the scan can read is counted.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(exclusions, id: \.self) { path in
                        HStack {
                            Text(path).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Remove") { exclusions.removeAll { $0 == path } }
                                .buttonStyle(.plain).foregroundStyle(.red)
                        }
                    }
                }.frame(minHeight: 120)
            }
            unobservedSection
            HStack {
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 420)
        .onAppear { if let t = tree { model.load(tree: t) } }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder private var unobservedSection: some View {
        if tree != nil {
            Divider()
            Text("Asked to skip, but never seen").font(.subheadline)
            Text("The scan never observed an entry at these paths. That is not proof they are absent.")
                .font(.caption).foregroundStyle(.secondary)
            if model.readFailed {
                Text("The report could not be read from the engine. The exclusions still apply; rescan to try again.")
                    .font(.caption).foregroundStyle(.red)
            } else if let list = model.unobserved {
                if list.isEmpty {
                    Text("Every exclusion matched something the scan saw.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(list, id: \.path) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.path).font(.callout).lineLimit(1).truncationMode(.middle)
                            Text(item.reason.label).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func add() {
        if let next = ExclusionEditing.adding(exclusions, draft) {
            exclusions = next
            draft = ""
        }
    }
}
