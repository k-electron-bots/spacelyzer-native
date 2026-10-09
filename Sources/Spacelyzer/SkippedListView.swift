import SwiftUI

// UNCOMPILED and UNRUN until a Mac run. Read-only: nothing here touches the filesystem,
// the Trash, or the engine's tables. The skipped list is fixed when a scan ends, so a
// captured Tree shows one consistent list with no invalidation wiring.

/// Reviewable list of the locations a scan skipped, grouped by reason, from one tree.
/// Every count and entry comes from the status-checked engine reads; a failed read is
/// shown as a failed read, never as an empty or partial list.
struct SkippedListView: View {
    let tree: Tree
    @State private var items: [SkippedItem]? = nil
    @State private var readFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Not scanned").font(.headline)
            Text("These locations were not scanned, so they are not in the totals.")
                .font(.caption).foregroundStyle(.secondary)
            if readFailed {
                Text("The list could not be read from the engine. The scan itself is unchanged; rescan to try again.")
                    .font(.caption).foregroundStyle(.red)
            } else if let items {
                if items.isEmpty {
                    Text("Nothing was skipped.").font(.caption).foregroundStyle(.secondary)
                } else {
                    summary(items)
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
        .onAppear { load() }
    }

    @ViewBuilder private func summary(_ items: [SkippedItem]) -> some View {
        switch tree.skippedCountsChecked() {
        case .success(let c):
            Text("\(items.count) skipped: \(c.permissionDenied) not allowed, \(c.unreadable) unreadable, \(c.separateVolume) on another volume, \(c.userExcluded) excluded")
                .font(.caption).foregroundStyle(.secondary)
        case .failure:
            EmptyView()   // the per-entry list still stands on its own status-checked reads
        }
    }

    private func load() {
        switch tree.skippedItemsChecked() {
        case .success(let list): items = list
        case .failure: readFailed = true
        }
    }
}
