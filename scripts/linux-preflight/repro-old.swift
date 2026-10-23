import Foundation
import CoreFoundation
// Exact pattern of d10bbf47 docs-capture.swift:185, with real corelibs CFString standing in for AXUIElement.
func read(_ element: CFString, _ name: String) -> CFTypeRef? { return nil }
func walk(_ cur0: CFString) {
    var cur = cur0
    for _ in 0..<64 {
        guard let parent = read(cur, "AXParent") as? CFString else { break }
        cur = parent
    }
}
