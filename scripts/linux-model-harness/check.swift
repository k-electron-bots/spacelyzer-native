import Foundation
@MainActor enum Check {
    static var fails = 0, passes = 0
    static func expect(_ n: String, _ ok: Bool, _ d: String = "") { if ok { passes += 1; print("PASS \(n)") } else { fails += 1; print("FAIL \(n) \(d)") } }
    static func note(_ s: String) { print("NOTE \(s)") }
}
