import Foundation

/// Pure parsing of the action names the in-process accessibility API vends. Run 39451419467 recorded
/// "Name:Show locations not scanned|Target:0x0|Selector:(null)" for the footer's one authored custom action: the API wraps the
/// authored name in AppKit's description of the action. The authored name is what the app sets; what VoiceOver speaks is not
/// established by this code. Foundation only, so it is compiled and executed on Linux by scripts/linux-model-harness.
enum AXActionName {
    /// The authored name, or nil when the string is malformed. A bare name (no "Name:" prefix) is returned as is. A wrapped
    /// name must be followed by both a Target: and a Selector: part (separated by "|" or a newline) and must not be empty.
    static func authored(_ vended: String) -> String? {
        guard vended.hasPrefix("Name:") else { return vended.isEmpty ? nil : vended }
        let rest = vended.dropFirst(5)
        guard let sep = rest.firstIndex(where: { $0 == "|" || $0 == "\n" }) else { return nil }
        let name = String(rest[..<sep])
        let tail = String(rest[rest.index(after: sep)...])
        guard !name.isEmpty, tail.contains("Target:"), tail.contains("Selector:") else { return nil }
        return name
    }
    /// The vended string to perform: the first action whose authored name is exactly `authored`.
    static func vended(in actions: [String], authored name: String) -> String? {
        actions.first { authored($0) == name }
    }
    /// Exactly one action, and its authored name is `name`. Any other authored name, a malformed string, or an extra action is false.
    static func isOnly(_ actions: [String], authored name: String) -> Bool {
        actions.count == 1 && authored(actions[0]) == name
    }
}
