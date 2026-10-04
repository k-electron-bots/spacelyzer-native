import AppKit
import Foundation

// UNCOMPILED and UNRUN until a Mac run. Read-only export of the Largest list as the scan recorded it. It reads nothing from the disk
// and touches no file except the one the user chooses in the save panel.

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

    /// Builds rows from one consistent read of the published arrays, then asks where to save. Writes only to the chosen file.
    func exportLargestCSV() {
        guard largestExportBlockedReason == nil, let tree else { return }
        let ids = largestIDs, sizes = largestSizes, gen = tree
        let rows = zip(ids, sizes).map { LargestCSV.Row(path: UInt64($0) < gen.nodeCount ? gen.path($0) : "", bytes: $1) }
        let (text, marked) = LargestCSV.csv(rows)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "spacelyzer-largest.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard self.tree === gen, largestExportBlockedReason == nil else {     // results changed while the panel was open: write nothing
            removalMessage = "The results changed while the save panel was open, so nothing was exported. Try again."
            return
        }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            removalMessage = marked == 0 ? "Exported \(rows.count) items. Sizes are what the scan recorded, not a check of the disk now."
                : "Exported \(rows.count) items; \(marked) with a path that could not be written exactly are marked in the note column. Sizes are what the scan recorded."
        } catch {
            removalMessage = "Could not write the file: \(error.localizedDescription)"
        }
    }
}
