#if SPZ_CI_TESTS
import Foundation

/// CI-only, fail-closed choice of the single attached sheet under an owning window.
/// Primary route: the AXSheets relationship. Only when AXSheets itself is reported
/// unsupported or empty (never for other errors) does the fallback look at the
/// window's own AXChildren for elements whose role is exactly AXSheet. Either route
/// must yield exactly one sheet. Zero, several, unreadable roles or any other error
/// select nothing. Nothing here reads sheet text; the caller walks the result.
enum AttachedSheetSelection<Element> {
    enum Route: String { case axSheets = "AXSheets", axChildrenRole = "AXChildren-role-AXSheet", none = "none" }
    struct Outcome { var sheet: Element?; var route: Route; var reason: String }
    static func select(owner: Element,
                       sheets: (Element) -> (rc: Int32, value: [Element]?),
                       children: (Element) -> (rc: Int32, value: [Element]?),
                       role: (Element) -> (rc: Int32, value: String?)) -> Outcome {
        let attributeUnsupported: Int32 = -25205, noValue: Int32 = -25212, success: Int32 = 0
        let s = sheets(owner)
        if s.rc == success, let list = s.value {
            if list.count == 1 { return Outcome(sheet: list[0], route: .axSheets, reason: "unique AXSheets") }
            if list.count > 1 { return Outcome(sheet: nil, route: .none, reason: "AXSheets count=\(list.count)") }
            // empty success falls through to the role fallback
        } else if s.rc != attributeUnsupported && s.rc != noValue {
            return Outcome(sheet: nil, route: .none, reason: "AXSheets error=\(s.rc)")
        }
        let c = children(owner)
        guard c.rc == success, let kids = c.value else { return Outcome(sheet: nil, route: .none, reason: "AXChildren error=\(c.rc)") }
        var matches: [Element] = []
        for kid in kids {
            let r = role(kid)
            guard r.rc == success, let name = r.value else { return Outcome(sheet: nil, route: .none, reason: "child role unreadable error=\(r.rc)") }
            if name == "AXSheet" { matches.append(kid) }
        }
        guard matches.count == 1 else { return Outcome(sheet: nil, route: .none, reason: "AXSheet children count=\(matches.count)") }
        return Outcome(sheet: matches[0], route: .axChildrenRole, reason: "unique AXSheet child after AXSheets rc=\(s.rc)")
    }
}
#endif
