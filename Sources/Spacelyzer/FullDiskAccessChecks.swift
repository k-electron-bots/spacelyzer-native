#if SPZ_CI_TESTS   // test-only code: compiled only when the build passes -Xswiftc -DSPZ_CI_TESTS
import Foundation

// UNCOMPILED and UNRUN until a Mac run. Regression checks for FullDiskAccessModel: the
// probe runs off the main actor and publishes on it, a refused probe opens the banner
// with its settings and re-check actions, an inconclusive probe is unknown - never
// granted, never refused - and a superseded probe answer is never published. The error
// mapping is pinned with synthetic errors; the machine's real TCC state is never
// asserted here. Bounded gates, no sleeps.
@MainActor
enum FullDiskAccessChecks {
    /// Bounded: wait() returns when opened or after about 5 s, whichever is first. A gate
    /// nobody opens makes the check FAIL, never hang the run.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock(); private var opened = false
        func wait() { for _ in 0..<500 where !isOpen { Thread.sleep(forTimeInterval: 0.01) } }
        func open() { lock.lock(); opened = true; lock.unlock() }
        var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return opened }
    }
    /// Bounded: polls cond for about 3 s.
    private static func settle(_ cond: () -> Bool) async { for _ in 0..<300 where !cond() { try? await Task.sleep(nanoseconds: 10_000_000) } }

    static func run() async {
        // 1. Error mapping: only a permission refusal is a refusal; missing directory,
        // other Cocoa errors and POSIX errors are inconclusive, so the probe can never
        // report a refusal for an unrelated failure.
        let refused = FullDiskAccessModel.outcome(forError: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)) == .refused
        let missing = FullDiskAccessModel.outcome(forError: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)) == .indeterminate
        let other = FullDiskAccessModel.outcome(forError: NSError(domain: NSCocoaErrorDomain, code: 512)) == .indeterminate
        let posix = FullDiskAccessModel.outcome(forError: NSError(domain: NSPOSIXErrorDomain, code: 13)) == .indeterminate
        Check.expect("fda-error-mapping-only-permission-refusal-is-refused", refused && missing && other && posix, "refused=\(refused) missing=\(missing) other=\(other) posix=\(posix)")

        // 2. Refused probe: banner visible, status and copy present, settings URL is the
        // Full Disk Access pane anchor.
        let m2 = FullDiskAccessModel(probe: { .refused })
        m2.refresh()
        await settle { m2.processedTokens.contains(1) }
        let copyOK = !FullDiskAccessModel.bannerTitle.isEmpty && !FullDiskAccessModel.bannerBody.isEmpty
            && !FullDiskAccessModel.openSettingsTitle.isEmpty && !FullDiskAccessModel.recheckTitle.isEmpty
            && FullDiskAccessModel.settingsURL.absoluteString.contains("Privacy_AllFiles")
        Check.expect("fda-refused-probe-opens-banner-with-settings-and-recheck", m2.status == .notGranted && m2.bannerVisible && m2.statusLabel == FullDiskAccessModel.notGrantedLabel && copyOK, "status=\(m2.status) banner=\(m2.bannerVisible) copyOK=\(copyOK)")

        // 3. Readable probe: granted, banner hidden.
        let m3 = FullDiskAccessModel(probe: { .readable })
        m3.refresh()
        await settle { m3.processedTokens.contains(1) }
        Check.expect("fda-readable-probe-grants-and-hides-banner", m3.status == .granted && !m3.bannerVisible && m3.statusLabel == FullDiskAccessModel.grantedLabel, "status=\(m3.status) banner=\(m3.bannerVisible)")

        // 4. Indeterminate probe: unknown, never granted, never a refusal, banner hidden.
        let m4 = FullDiskAccessModel(probe: { .indeterminate })
        m4.refresh()
        await settle { m4.processedTokens.contains(1) }
        Check.expect("fda-indeterminate-probe-is-unknown-never-granted", m4.status == .unknown && !m4.bannerVisible && m4.statusLabel == FullDiskAccessModel.unknownLabel, "status=\(m4.status) banner=\(m4.bannerVisible)")

        // 5. Supersede: the first probe parks; a newer refresh answers refused; the parked
        // answer (readable) is processed later but never published.
        final class ParkBox: @unchecked Sendable {
            let gate = Gate(); let lock = NSLock(); var calls = 0
            func next() -> FullDiskAccessProbeOutcome {
                lock.lock(); calls += 1; let mine = calls; lock.unlock()
                if mine == 1 { gate.wait(); return .readable }
                return .refused
            }
        }
        let box = ParkBox()
        let m5 = FullDiskAccessModel(probe: { box.next() })
        m5.refresh()
        let parked = m5.status == .notChecked && m5.token == 1
        m5.refresh()
        await settle { m5.processedTokens.contains(2) }
        let answered = m5.status == .notGranted
        box.gate.open()
        await settle { m5.processedTokens.contains(1) }
        Check.expect("fda-refresh-supersedes-parked-probe", parked && answered && m5.processedTokens.contains(1) && m5.status == .notGranted && m5.token == 2, "parked=\(parked) answered=\(answered) late=\(m5.processedTokens.contains(1)) status=\(m5.status)")

        // 6. Copy hygiene: the new strings carry no health wording.
        let copy = [FullDiskAccessModel.bannerTitle, FullDiskAccessModel.bannerBody,
                    FullDiskAccessModel.openSettingsTitle, FullDiskAccessModel.recheckTitle,
                    FullDiskAccessModel.grantedLabel, FullDiskAccessModel.notGrantedLabel,
                    FullDiskAccessModel.unknownLabel]
        let hasHealth = copy.contains { $0.lowercased().contains("health") }
        Check.expect("fda-copy-has-no-health-wording", !hasHealth && copy.count == 7, hasHealth ? "health wording present" : "7 strings clean")
    }
}
#endif
