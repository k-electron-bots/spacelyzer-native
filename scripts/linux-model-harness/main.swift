import Foundation
// Runs the real MultiSelectChecks. The final DONE line lets compare.sh tell a completed run from a crash or truncated output.
@MainActor func go() async {
    await MultiSelectChecks.run()
    print("DONE passes=\(Check.passes) fails=\(Check.fails)")
    exit(Check.fails == 0 ? 0 : 1)
}
await go()
