import Foundation

// UNCOMPILED and UNRUN until a Mac run. Pure policy for copying the SCANNED path of an item. It does not read the disk and does not
// alter the path: a path that cannot be copied exactly and safely is refused, never cleaned up.

enum CopyPathPolicy {
    enum Refusal: Sendable, Equatable {
        case engineUntrusted, noItem, emptyPath, lossyName, controlCharacters
        var help: String {
            switch self {
            case .engineUntrusted: return "The engine reported an internal error. Rescan to continue."
            case .noItem: return "This item is no longer in the results."
            case .emptyPath: return "There is no path to copy."
            case .lossyName: return "This name has bytes the scan could not keep exactly, so a copied path could point somewhere else."
            case .controlCharacters: return "This name contains control or line-break characters. Pasted into a terminal it could run something unintended, so it is not copied. Use Show in Finder."
            }
        }
    }
    enum Decision: Sendable, Equatable { case copy(String), refuse(Refusal) }

    /// Never alters `path`. Control characters: C0 (below 0x20), DEL, C1 (0x80-0x9F), and the Unicode line/paragraph separators.
    static func decide(path: String?, enginePoisoned: Bool) -> Decision {
        if enginePoisoned { return .refuse(.engineUntrusted) }
        guard let path else { return .refuse(.noItem) }
        if path.isEmpty { return .refuse(.emptyPath) }
        if path.unicodeScalars.contains(where: { $0.value == 0xFFFD }) { return .refuse(.lossyName) }
        if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || ($0.value >= 0x80 && $0.value <= 0x9F) || $0.value == 0x2028 || $0.value == 0x2029 }) { return .refuse(.controlCharacters) }
        return .copy(path)
    }

    /// Decides again at the moment of the click, from the CURRENT state, and only then calls `write`. A refusal never calls it, so a
    /// refused click cannot clear the clipboard. Returns what happened.
    @discardableResult
    static func perform(path: String?, enginePoisoned: Bool, write: (String) -> Void) -> Decision {
        let d = decide(path: path, enginePoisoned: enginePoisoned)
        if case .copy(let p) = d { write(p) }
        return d
    }
}
