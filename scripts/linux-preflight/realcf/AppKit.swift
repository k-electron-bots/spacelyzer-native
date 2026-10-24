// OFFLINE STUB for Linux typecheck - NOT the macOS SDK.
import Foundation

open class NSRunningApplication: NSObject {
    public override init() { super.init() }
    public init?(processIdentifier pid: pid_t) { super.init() }
    public func activate() -> Bool { false }
}

public class NSScreen {
 public static var screens: [NSScreen] { [] }
 public var frame: CGRect { .zero }
 public var visibleFrame: CGRect { .zero }
 public var backingScaleFactor: Double { 1 }
}
