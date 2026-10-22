// swift-tools-version:5.9
import PackageDescription
import Foundation

let ciEngine = ProcessInfo.processInfo.environment["SPZ_CI_ENGINE"] == "1"

// The Rust engine is built first (scripts/build-engine.sh) into build/lib/libspacelyzer_engine.a.
let package = Package(
    name: "Spacelyzer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Spacelyzer", targets: ["Spacelyzer"])],
    targets: [
        .target(name: "CSpacelyzer", path: "Sources/CSpacelyzer"),
        .executableTarget(
            name: "Spacelyzer",
            dependencies: ["CSpacelyzer"],
            path: "Sources/Spacelyzer",
            linkerSettings: [
                .unsafeFlags(ciEngine ? ["-Lbuild/ci-lib", "-lspacelyzer_ci"] : ["-Lbuild/lib", "-lspacelyzer_engine"]),
            ]
        ),
    ]
)
