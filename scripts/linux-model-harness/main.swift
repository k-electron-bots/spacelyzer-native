import Foundation
@MainActor func go() async { await MultiSelectChecks.run() }
await go()
