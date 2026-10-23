// OFFLINE STUB for Linux typecheck - NOT the macOS SDK.
import Foundation

open class NSRunningApplication: NSObject {
    public override init() { super.init() }
    public init?(processIdentifier pid: pid_t) { super.init() }
    public func activate() -> Bool { false }
}
