import SwiftUI

// UNCOMPILED and UNRUN until a Mac run. Shows the raw statvfs capacity of the scanned
// volume. These are kernel numbers: total minus free is NOT "used by files" (purgeable
// space, APFS snapshots and container sharing are not separated by statvfs), and nothing
// here is a reclaimable-space figure. Read-only: no filesystem or engine mutation.

/// Owns the one volume-capacity read in flight. statvfs blocks the calling thread (it can
/// stall on a hung network mount), so the read is OFF the main actor and the publish is on
/// it. A late answer is shown only while its request token is still current.
@MainActor
final class VolumeHeaderModel: ObservableObject {
    typealias Reader = @Sendable (String) async -> Result<VolumeInfo, VolumeReadError>
    @Published private(set) var info: VolumeInfo?
    @Published private(set) var failure: VolumeReadError?
    private var task: Task<Void, Never>?
    private var path: String?
    /// Id of the latest load. Read-only outside; tests use it to wait for a specific load's processing.
    private(set) var token = 0
    #if SPZ_CI_TESTS
    /// TEST BUILDS ONLY. Tokens whose read has returned and been through the publish logic.
    private(set) var processedTokens: Set<Int> = []
    #endif
    private let reader: Reader

    init(reader: @escaping Reader = { volumeInfoChecked(path: $0) }) {
        self.reader = reader
    }

    /// Reads the capacity of the volume holding `path`, off-main. A repeat call for the same
    /// path with a result already published is ignored: the numbers belong to one scan and
    /// are not refreshed under it. A different path supersedes any read in flight.
    func load(path: String) {
        guard path != self.path || (info == nil && failure == nil) else { return }
        task?.cancel()
        self.path = path
        token += 1
        let mine = token
        info = nil; failure = nil
        let reader = self.reader
        task = Task.detached(priority: .utility) { [weak self] in
            let result = await reader(path)                // off-main: statvfs can stall
            await MainActor.run {
                guard let self else { return }
                #if SPZ_CI_TESTS
                self.processedTokens.insert(mine)
                #endif
                guard mine == self.token, !Task.isCancelled else { return }   // superseded: never publish
                switch result {
                case .success(let v): self.info = v
                case .failure(let e): self.failure = e
                }
            }
        }
    }
}

/// Raw capacity of the scanned volume in the footer: "X available of Y". A failed read is a
/// failed read, never a guessed number. A saturated figure is not shown as a number. While
/// the read is in flight the footer stays quiet: one statvfs call is sub-second on a healthy
/// volume, and a spinner would outlive the read.
struct VolumeHeaderView: View {
    let rootPath: String?
    @StateObject private var model: VolumeHeaderModel

    init(rootPath: String?, model: VolumeHeaderModel? = nil) {
        self.rootPath = rootPath
        _model = StateObject(wrappedValue: model ?? VolumeHeaderModel())
    }

    var body: some View {
        if let rootPath {
            content
                .onAppear { model.load(path: rootPath) }
                .onChange(of: rootPath) { _, new in model.load(path: new) }
        }
    }

    @ViewBuilder private var content: some View {
        if let f = model.failure {
            Text(failureText(f)).foregroundStyle(.secondary)
        } else if let v = model.info {
            if v.saturated {
                Text("Volume capacity could not be measured").foregroundStyle(.secondary)
            } else {
                Text("\(formatBytes(v.availableBytes)) available of \(formatBytes(v.totalBytes))" + (v.readOnly ? " (read-only)" : ""))
                    .foregroundStyle(.secondary)
                    .help("Raw filesystem numbers: available subtracts what the volume reserves. Total minus free is not \"used by files\".")
            }
        } else {
            EmptyView()
        }
    }

    private func failureText(_ e: VolumeReadError) -> String {
        switch e {
        case .invalid: "Volume capacity could not be read"
        case .osError(let n): "Volume capacity could not be read (system error \(n))"
        }
    }
}
