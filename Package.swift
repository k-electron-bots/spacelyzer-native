// swift-tools-version:5.9
import PackageDescription

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
                .unsafeFlags(["-Lbuild/lib", "-lspacelyzer_engine"]),
            ]
        ),
    ]
)
