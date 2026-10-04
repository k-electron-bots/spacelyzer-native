import AppKit
import Foundation
import UniformTypeIdentifiers

// UNCOMPILED and UNRUN until a Mac run. Read-only export of the Largest list as the scan recorded it. It reads nothing from the disk
// and touches no file except the one the user chooses in the save panel.
// Format, a deliberate choice: UTF-8 WITHOUT a byte order mark, CRLF line ends. Names are written byte-exact. Excel may misread non-ASCII
// names when it opens the file directly; "Data > From Text/CSV" with UTF-8 selected reads it right. Nothing here has been tested in Excel.
// Bound: the Largest list is built with count 200 (AppModel.refreshDerived), and export refuses more than `maxRows` as a defensive limit.

enum LargestCSV {
    /// RFC 4180 quoting: a field is quoted when it holds a comma, quote, CR or LF, and quotes are doubled. A path that would start with a
    /// spreadsheet formula character is marked in `csv` instead of being altered.
    static func field(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    struct Row: Sendable, Equatable { var path: String; var bytes: UInt64 }

    /// A path that is not exactly representable (lossy name) or starts with a formula character is exported with an EMPTY path and a note,
    /// never altered, so a row is either exact or visibly marked. Control characters inside a path are legal in a quoted field.
    static func csv(_ rows: [Row]) -> (text: String, markedRows: Int) {
        var out = "rank,size_bytes_on_disk_at_scan,path,note\r\n"
        var marked = 0
        for (i, r) in rows.enumerated() {
            let lossy = r.path.unicodeScalars.contains { $0.value == 0xFFFD }
            let formula = r.path.first.map { "=+-@\t\r".contains($0) } ?? false
            if r.path.isEmpty || lossy || formula {
                marked += 1
                let why = r.path.isEmpty ? "no path" : lossy ? "name not exactly representable" : "path starts with a formula character"
                out += "\(i + 1),\(r.bytes),,\(field(why))\r\n"
            } else {
                out += "\(i + 1),\(r.bytes),\(field(r.path)),\r\n"
            }
        }
        return (out, marked)
    }
}

/// Everything an export depends on, captured BEFORE the save panel opens and compared again after it closes.
struct LargestExportSnapshot: Sendable, Equatable {
    var treeID: ObjectIdentifier
    var treeVersion: UInt64
    var derivedVersion: UInt64?
    var filterRevision: Int
    var revision: Int
    var ids: [UInt32]
    var sizes: [UInt64]
}

enum LargestExport {
    static let maxRows = 1000
    enum Outcome: Sendable, Equatable {
        case blocked(String)            // not started: panel never opened
        case tooLarge(Int)
        case cancelledByUser            // panel dismissed
        case staleAfterPanel            // anything changed while the panel was open or the data was prepared: nothing written
        case cancelledTask              // the task was cancelled: nothing written
        case written(rows: Int, marked: Int, changedDuringWrite: Bool)   // the file holds the list as captured at export time
        case failed(String)
    }

    /// Runs `op` on a detached task and forwards cancellation of the caller to it (a detached task does not inherit cancellation).
    /// Cancellation is only observed where `op` checks it: the row loop does, so preparation stops. A file write that has started is NOT
    /// interrupted, and a cancel that arrives after it began can still leave the file on disk.
    private static func detached<T: Sendable>(_ priority: TaskPriority, _ op: @escaping @Sendable () throws -> T) async throws -> T {
        let work = Task.detached(priority: priority) { try op() }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// The whole flow with every effect injected, so a test can drive it without a window or a disk.
    /// Order: blocked? -> snapshot -> panel -> unchanged? -> build off the main actor -> unchanged? -> write. Any change: nothing is written.
    @MainActor
    static func run(blockedReason: () -> String?, snapshot: () -> LargestExportSnapshot?, askURL: () -> URL?,
                    path: @escaping @Sendable (UInt32) -> String, write: @escaping @Sendable (Data, URL) throws -> Void) async -> Outcome {
        if let r = blockedReason() { return .blocked(r) }
        guard let snap = snapshot() else { return .blocked("Nothing has been scanned.") }
        if snap.ids.count > maxRows { return .tooLarge(snap.ids.count) }
        guard let url = askURL() else { return .cancelledByUser }
        if snapshot() != snap || blockedReason() != nil { return .staleAfterPanel }
        let built: (text: String, markedRows: Int)?
        do {
            built = try await detached(.userInitiated) { () -> (String, Int)? in
                var rows: [LargestCSV.Row] = []
                rows.reserveCapacity(snap.ids.count)
                for (id, bytes) in zip(snap.ids, snap.sizes) {
                    if Task.isCancelled { return nil }
                    rows.append(.init(path: path(id), bytes: bytes))
                }
                return LargestCSV.csv(rows)
            }
        } catch { return .failed(error.localizedDescription) }
        guard let built else { return .cancelledTask }
        if Task.isCancelled { return .cancelledTask }
        if snapshot() != snap || blockedReason() != nil { return .staleAfterPanel }          // last check BEFORE the write; nothing guards after it starts
        let data = Data(built.text.utf8)
        do {
            try await detached(.utility) { try write(data, url) }
        } catch { return .failed(error.localizedDescription) }
        // The stale checks above only detect changes BEFORE the write began. A change during the write cannot undo the file; say so.
        return .written(rows: snap.ids.count, marked: built.markedRows, changedDuringWrite: snapshot() != snap)
    }
}

extension AppModel {
    /// Disabled-state reason, or nil when the Largest list is current and trustworthy.
    var largestExportBlockedReason: String? {
        if tree == nil { return "Nothing has been scanned." }
        if enginePoisoned { return "The engine reported an internal error. Rescan to continue." }
        if viewOutOfDate { return outOfDateReason ?? "The results may be out of date. Rescan to refresh." }
        if rowsPending || filterPending { return "The list is still updating." }
        if largestIDs.isEmpty || largestIDs.count != largestSizes.count { return "There is nothing to export." }
        return nil
    }

    func largestExportSnapshot() -> LargestExportSnapshot? {
        guard let tree else { return nil }
        return LargestExportSnapshot(treeID: ObjectIdentifier(tree), treeVersion: tree.version, derivedVersion: derivedVersion,
                                     filterRevision: filterRevision, revision: revision, ids: largestIDs, sizes: largestSizes)
    }

    /// Words for an outcome. A separate message from `removalMessage`, which belongs to Trash and its Undo button.
    static func exportText(_ o: LargestExport.Outcome) -> String? {
        switch o {
        case .cancelledByUser, .cancelledTask: return nil
        case .blocked(let r): return r
        case .tooLarge(let n): return "The list has \(n) items, more than the \(LargestExport.maxRows) this export allows. Nothing was exported."
        case .staleAfterPanel: return "The results changed while exporting, so nothing was written. Try again."
        case .written(let n, let m, let changed):
            var t = "Exported \(n) items (UTF-8, no byte order mark). Sizes are what the scan recorded, not a check of the disk now."
            if m > 0 { t += " \(m) with a path that could not be written exactly are marked in the note column." }
            if changed { t += " The results changed while the file was being written. The file holds the list as it was when you chose the location." }
            return t
        case .failed(let e): return "Could not write the file: \(e)"
        }
    }

    /// The real export wiring with the panel and the write injected, so a test can run it against a real AppModel.
    func exportLargest(askURL: @escaping () -> URL?, write: @escaping @Sendable (Data, URL) throws -> Void) async {
        guard let tree else { return }
        let outcome = await LargestExport.run(
            blockedReason: { [weak self] in self?.largestExportBlockedReason },
            snapshot: { [weak self] in self?.largestExportSnapshot() },
            askURL: askURL,
            path: { tree.path($0) },
            write: write)
        exportMessage = Self.exportText(outcome)
        lastExportOutcome = outcome
    }

    /// Production entry. While the save panel is open the main actor is blocked, so a second export cannot start until it is dismissed.
    func exportLargestCSV() {
        guard exportTask == nil else { return }
        exportTask = Task { [weak self] in
            guard let self else { return }
            await self.exportLargest(
                askURL: {
                    let panel = NSSavePanel()          // the panel confirms before replacing an existing file (native behavior, not verified here)
                    panel.nameFieldStringValue = "spacelyzer-largest.csv"
                    panel.allowedContentTypes = [.commaSeparatedText]
                    return panel.runModal() == .OK ? panel.url : nil
                },
                write: { data, url in try data.write(to: url, options: .atomic) })
            self.exportTask = nil
        }
    }
}
