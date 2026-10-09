import AppKit
import SwiftUI

// UNCOMPILED and UNRUN until a Mac run. E5 scan control: Full Disk Access detection.
// Read-only: the probe lists one protected directory (~/Library/Safari) and keeps nothing
// from it; no scan, no write, no settings change. A refused read means the protected
// location is not readable; a missing directory or any other error means the probe cannot
// conclude and is reported as unknown - never as granted, never as refused.

/// The three answers a probe can honestly give. Only `.refused` opens the banner: an
/// inconclusive read is shown as unknown, never treated as granted or refused.
enum FullDiskAccessProbeOutcome: Equatable {
    case readable, refused, indeterminate
}

enum FullDiskAccessStatus: Equatable {
    case notChecked, granted, notGranted, unknown
}

/// Owns the one Full Disk Access probe in flight. The probe runs OFF the main actor (it
/// touches a protected path and must never stall the UI), the publish is on the main
/// actor, and a late answer lands only while its request token is still current: a newer
/// refresh() makes the late answer a no-op.
@MainActor
final class FullDiskAccessModel: ObservableObject {
    typealias Probe = @Sendable () -> FullDiskAccessProbeOutcome

    // UI state copy. Facts only: what is the case and what changes because of it.
    static let bannerTitle = "Full Disk Access is not granted"
    static let bannerBody = "Spacelyzer cannot read some folders, so their sizes are not in the scan totals. The Not scanned list shows what was skipped."
    static let openSettingsTitle = "Open System Settings"
    static let recheckTitle = "Re-check"
    static let grantedLabel = "Full Disk Access is granted"
    static let notGrantedLabel = "Full Disk Access is not granted"
    static let unknownLabel = "Full Disk Access could not be determined"
    /// macOS 13+ Privacy & Security pane, Full Disk Access anchor. Older macOS opens the pane root.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
    /// Protected location used by the default probe: readable only with Full Disk Access.
    static let probePath = NSHomeDirectory() + "/Library/Safari"

    @Published private(set) var status: FullDiskAccessStatus = .notChecked
    /// Id of the latest refresh. Read-only outside; checks use it to wait for a specific probe.
    private(set) var token = 0
    #if SPZ_CI_TESTS
    /// TEST BUILDS ONLY. Tokens whose probe has returned and been through the publish logic
    /// (published, dropped or superseded). Lets a check wait for a late probe instead of sleeping.
    private(set) var processedTokens: Set<Int> = []
    #endif
    private var task: Task<Void, Never>?
    private let probe: Probe

    init(probe: @escaping Probe = FullDiskAccessModel.defaultProbe) { self.probe = probe }

    /// The default probe: one directory listing of the protected path. A refusal means the
    /// location is not readable; a missing directory or any other error is inconclusive.
    static func defaultProbe() -> FullDiskAccessProbeOutcome {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: probePath)
            return .readable
        } catch let error as NSError {
            return outcome(forError: error)
        }
    }

    /// Error mapping, factored out so checks can pin it with synthetic errors: only a
    /// permission refusal is a refusal; every other error leaves the probe inconclusive.
    static func outcome(forError error: NSError) -> FullDiskAccessProbeOutcome {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError { return .refused }
        return .indeterminate
    }

    /// Starts the off-main probe and returns immediately. Previous probes are superseded,
    /// never stacked.
    func refresh() {
        task?.cancel()
        token += 1
        let mine = token
        let probe = self.probe
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = probe()                       // off-main: touches a protected path
            await MainActor.run {
                guard let self else { return }
                #if SPZ_CI_TESTS
                self.processedTokens.insert(mine)
                #endif
                guard mine == self.token, !Task.isCancelled else { return }   // superseded: never publish
                switch outcome {
                case .readable: self.status = .granted
                case .refused: self.status = .notGranted
                case .indeterminate: self.status = .unknown
                }
            }
        }
    }

    var bannerVisible: Bool { status == .notGranted }
    var statusLabel: String {
        switch status {
        case .notChecked: return ""
        case .granted: return Self.grantedLabel
        case .notGranted: return Self.notGrantedLabel
        case .unknown: return Self.unknownLabel
        }
    }
}

/// Banner shown only while the probe says a protected location is not readable. When the
/// probe is inconclusive nothing is claimed either way; when access is granted the banner
/// stays out of the UI. The probe starts on appear even while the banner is hidden,
/// because only its answer decides whether there is anything to show.
struct FullDiskAccessBanner: View {
    @StateObject private var model: FullDiskAccessModel

    init(model: FullDiskAccessModel? = nil) {
        _model = StateObject(wrappedValue: model ?? FullDiskAccessModel())
    }

    var body: some View {
        Group {
            if model.bannerVisible {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "lock.shield")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(FullDiskAccessModel.bannerTitle).font(.callout).bold()
                        Text(FullDiskAccessModel.bannerBody).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(FullDiskAccessModel.openSettingsTitle) {
                        NSWorkspace.shared.open(FullDiskAccessModel.settingsURL)
                    }
                    .help("Open the Full Disk Access list in System Settings")
                    Button(FullDiskAccessModel.recheckTitle) { model.refresh() }
                        .help("Probe the protected location again")
                }
                .padding(10)
                .background(.bar)
            }
        }
        .background(Color.clear.onAppear { model.refresh() })   // fires even while hidden
    }
}
