import Foundation
@MainActor final class AppModel { var removalMessage: String? = nil; var scanning = false }
@MainActor enum DemoInput {
    static var window: Int? { 1 }
    static func stateLine(step: Int, alertShown: Bool) -> String { "step=\(step) alert=\(alertShown) \(window != nil)" }
}
@MainActor func driver(model: AppModel) async {
    let run: @MainActor () async -> Void = {
        @MainActor func mark(_ n: Int) { try? (DemoInput.stateLine(step: n, alertShown: model.removalMessage != nil) + "\n").write(toFile: "/tmp/x\(n)", atomically: true, encoding: .utf8) }
        @MainActor func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) { action() }
        @MainActor func drive(step: Int?) { if let step { schedule(0.4) { mark(step) } } }
        mark(1)
        try? await Task.sleep(nanoseconds: 1)
        model.removalMessage = nil
        mark(2); drive(step: 3)
    }
    await run()
}
