import Foundation
import UniformTypeIdentifiers
public final class NSImage {}
public final class NSPasteboard { public static let general = NSPasteboard() }
public struct NSEventModifierFlags: OptionSet { public let rawValue: Int; public init(rawValue: Int) { self.rawValue = rawValue }
  public static let command = Self(rawValue: 1), control = Self(rawValue: 2), option = Self(rawValue: 4), shift = Self(rawValue: 8) }
open class NSResponder {}
open class NSView: NSResponder {
  public var window: NSWindow?; public var nextKeyView: NSView?; public var isHiddenOrHasHiddenAncestor = false; public var acceptsFirstResponder = true }
open class NSControl: NSView { public var isEnabled = true }
open class NSTableView: NSControl {}
open class NSTextField: NSControl {}
open class NSTextView: NSView { public var delegate: AnyObject?; public func hasMarkedText() -> Bool { false } }
open class NSEvent { public typealias ModifierFlags = NSEventModifierFlags }
open class NSWindow { public var isKeyWindow = true, isVisible = true; public var firstResponder: NSResponder?; public func makeFirstResponder(_ r: NSResponder?) -> Bool { firstResponder = r; return true } }
public final class NSApplication { public var isActive = true }
public let NSApp = NSApplication()
public final class NSWorkspace { public static let shared = NSWorkspace(); public func activateFileViewerSelecting(_ u: [URL]) {} }
public final class NSOpenPanel { public init() {}; public var canChooseDirectories = false, canChooseFiles = true, prompt = ""; public var url: URL?
  public enum R { case OK, cancel }; public func runModal() -> R { .cancel } }
public final class NSSavePanel { public init() {}; public var nameFieldStringValue = ""; public var allowedContentTypes: [UTType] = []; public var url: URL?
  public func runModal() -> NSOpenPanel.R { .cancel } }
