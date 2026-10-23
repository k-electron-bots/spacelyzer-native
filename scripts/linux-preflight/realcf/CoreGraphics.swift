// OFFLINE STUB for Linux typecheck - NOT the macOS SDK. Window-list keys are String constants
// (declared deviation: on macOS they are CFString; the helper bridges with `as String`).
import Foundation
import CoreFoundation

public typealias CGWindowID = UInt32
public typealias CGKeyCode = UInt16
public typealias UniChar = UInt16

public struct CGWindowListOption: OptionSet {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let optionOnScreenOnly = CGWindowListOption(rawValue: 1 << 0)
    public static let excludeDesktopElements = CGWindowListOption(rawValue: 1 << 4)
}

public let kCGNullWindowID: CGWindowID = 0
public let kCGWindowOwnerPID = "kCGWindowOwnerPID"
public let kCGWindowLayer = "kCGWindowLayer"
public let kCGWindowNumber = "kCGWindowNumber"
public let kCGWindowBounds = "kCGWindowBounds"
public let kCGWindowAlpha = "kCGWindowAlpha"

public func CGWindowListCopyWindowInfo(_ options: CGWindowListOption, _ relativeToWindow: CGWindowID) -> CFArray? { nil }

public enum CGEventTapLocation { case cghidEventTap }

open class CGEvent {
    public init?(keyboardEventSource: Any?, virtualKey: CGKeyCode, keyDown: Bool) {}
    public func keyboardSetUnicodeString(stringLength: Int, unicodeString: UnsafePointer<UniChar>?) {}
    public func post(tap: CGEventTapLocation) {}
}
