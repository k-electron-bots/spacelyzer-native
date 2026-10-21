import Foundation
extension FileManager { func trashItem(at: URL, resultingItemURL: UnsafeMutablePointer<NSURL?>?) throws {} }
enum QuickLookController { struct P { var paths: [String]; var focus: Int }
  static func payload(memberPaths: [String], focusPath: String?) -> P? { nil }
  static func show(paths: [String], focus: Int) -> Bool { false } }
@MainActor enum DuplicateRemoval {   // HARNESS STUB: the real one lives in a SwiftUI view file
  static func blockedReason(_ p: String, groupPaths: [String], in m: AppModel) -> String? { nil }
  static func liveID(_ p: String, in m: AppModel) -> UInt32? { nil } }
