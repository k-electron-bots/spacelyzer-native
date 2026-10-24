// Minimal macOS-SDK stubs for Linux typechecking of docs-capture.swift.
// CF/AX types are aliased to NS classes so String bridging works on Linux; this means the
// compiler's "conditional downcast to CoreFoundation type always succeeds" rule CANNOT fire
// for AXUIElement here - that class is covered separately by targeted real-CoreFoundation probes.
import Foundation
import Glibc
public typealias CFString = NSString
public typealias CFTypeRef = AnyObject
public typealias CFBoolean = NSNumber
public typealias CFArray = NSArray
public let kCFBooleanTrue: CFBoolean = NSNumber(value: true)
public typealias AXUIElement = NSString
public typealias AXValue = NSNumber
public enum AXError: Int32 { case success = 0, failure = -25200, attributeUnsupported = -25205, noValue = -25212 }
public func AXUIElementCreateApplication(_ pid: Int32) -> AXUIElement { fatalError() }
public func AXUIElementCopyAttributeValue(_ element: AXUIElement, _ name: CFString, _ result: UnsafeMutablePointer<CFTypeRef?>) -> AXError { fatalError() }
public func AXUIElementPerformAction(_ element: AXUIElement, _ action: CFString) -> AXError { fatalError() }
public func AXUIElementSetAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError { fatalError() }
public enum AXValueType { case cgPoint, cgSize }
public func AXValueGetValue(_ value: AXValue, _ type: AXValueType, _ out: UnsafeMutableRawPointer) -> Bool { fatalError() }
public func CFHash(_ cf: CFTypeRef) -> UInt { fatalError() }
public func CFEqual(_ a: CFTypeRef, _ b: CFTypeRef) -> Bool { fatalError() }
public final class NSRunningApplication {
    public init?(processIdentifier: Int32) {}
    public func activate() {}
}
public typealias CGKeyCode = UInt16
public typealias UniChar = UInt16
public enum CGEventTapLocation { case cghidEventTap }
public final class CGEvent {
    public init?(keyboardEventSource: Any?, virtualKey: CGKeyCode, keyDown: Bool) {}
    public func post(tap: CGEventTapLocation) {}
    public func keyboardSetUnicodeString(stringLength: Int, unicodeString: UnsafePointer<UniChar>?) {}
}
public typealias CGWindowID = UInt32
public let kCGNullWindowID: CGWindowID = 0
public struct CGWindowListOption: OptionSet {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let optionOnScreenOnly = CGWindowListOption(rawValue: 1)
    public static let excludeDesktopElements = CGWindowListOption(rawValue: 2)
}
public let kCGWindowNumber: CFString = "kCGWindowNumber"
public let kCGWindowOwnerPID: CFString = "kCGWindowOwnerPID"
public let kCGWindowBounds: CFString = "kCGWindowBounds"
public func CGWindowListCopyWindowInfo(_ option: CGWindowListOption, _ relativeToWindow: CGWindowID) -> CFArray? { fatalError() }
public typealias CGFloat = Double
public struct CGPoint { public var x: CGFloat; public var y: CGFloat; public static let zero = CGPoint(x: 0, y: 0) }
public struct CGSize { public var width: CGFloat; public var height: CGFloat; public static let zero = CGSize(width: 0, height: 0) }
public let kCGWindowLayer: CFString = "kCGWindowLayer"
public let kCGWindowAlpha: CFString = "kCGWindowAlpha"

public func AXValueCreate(_ type: AXValueType, _ valuePtr: UnsafeRawPointer) -> AXValue? { fatalError("stub") }
