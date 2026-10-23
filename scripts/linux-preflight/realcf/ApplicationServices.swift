// OFFLINE STUB for Linux typecheck - NOT the macOS SDK. AXUIElement/AXValue are typealiased to REAL
// CoreFoundation types so the compiler's CF-cast diagnostics fire exactly as on macOS (verified:
// "conditional downcast to CoreFoundation type ... will always succeed" reproduces on Linux 6.1.2).
import Foundation
import CoreFoundation

public typealias AXUIElement = CFDictionary
public typealias AXValue = CFArray
public typealias pid_t = Int32

public enum AXError: Int32 { case success = 0, attributeUnsupported = -25205, noValue = -25212 }
public enum AXValueType: Int32 { case cgPoint = 1, cgSize = 2 }

public func AXUIElementCreateApplication(_ pid: pid_t) -> AXUIElement { fatalError("stub") }
public func AXUIElementCopyAttributeValue(_ element: AXUIElement, _ attribute: String, _ value: UnsafeMutablePointer<CFTypeRef?>) -> AXError { fatalError("stub") }
public func AXUIElementPerformAction(_ element: AXUIElement, _ action: String) -> AXError { fatalError("stub") }
public func AXUIElementSetAttributeValue(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError { fatalError("stub") }
public func AXValueGetValue(_ value: AXValue, _ type: AXValueType, _ valuePtr: UnsafeMutableRawPointer) -> Bool { fatalError("stub") }

// Extended surface for ax-client.swift (exact macOS CFString signatures + String overloads for the
// docs-capture transform; overloads are a declared stub mechanism, both resolve to the same semantics).
public func AXIsProcessTrusted() -> Bool { fatalError("stub") }
public func AXUIElementGetPid(_ element: AXUIElement, _ pid: UnsafeMutablePointer<pid_t>) -> AXError { fatalError("stub") }
public func AXUIElementCopyAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: UnsafeMutablePointer<CFTypeRef?>) -> AXError { fatalError("stub") }
public func AXUIElementPerformAction(_ element: AXUIElement, _ action: CFString) -> AXError { fatalError("stub") }

public let kAXTitleAttribute = "AXTitle"
public let kAXChildrenAttribute = "AXChildren"
public let kAXDescriptionAttribute = "AXDescription"
public let kAXHelpAttribute = "AXHelp"
public let kAXRoleAttribute = "AXRole"
public let kAXStaticTextRole = "AXStaticText"
public let kAXValueAttribute = "AXValue"
public let kAXWindowRole = "AXWindow"
public let kAXWindowsAttribute = "AXWindows"
