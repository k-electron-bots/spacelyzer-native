import Foundation
import CoreFoundation
// Exact pattern of 7180780c's fix.
func read(_ element: CFString, _ name: String) -> CFTypeRef? { return nil }
func walk(_ cur0: CFString) {
    var cur = cur0
    for _ in 0..<64 {
        guard let parentRef = read(cur, "AXParent") else { break }
        let parent = parentRef as! CFString
        cur = parent
    }
}
