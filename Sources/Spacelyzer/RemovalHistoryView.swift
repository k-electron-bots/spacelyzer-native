import SwiftUI

/// Removal history (E4e): every removal journaled this session, newest first, each with its own
/// Put Back. A restore moves the item back on disk through the same gates as the alert's Undo; the
/// engine cannot add a subtree back, so the model then marks the view out of date and asks for a
/// rescan. Opening this popover moves nothing.
struct RemovalHistoryPopover: View {
    let model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Removed this session").font(.headline)
            if model.lastRemoved.isEmpty {
                Text("Nothing removed yet.").foregroundStyle(.secondary)
            } else {
                ForEach(model.lastRemoved.reversed()) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.original.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Text(item.original.deletingLastPathComponent().path)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Spacer(minLength: 8)
                        Text(formatBytes(item.size)).font(.caption).foregroundStyle(.secondary)
                        Button("Put Back") { model.restoreRemoved(id: item.id) }
                            .disabled(model.removalInFlight || model.mutationPending)
                            .help(model.removalInFlight || model.mutationPending ? "The previous change is still being applied." : "Move it back to its original location, then rescan")
                            .accessibilityLabel("Put \(item.original.lastPathComponent) back")
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 380, maxWidth: 480)
    }
}
