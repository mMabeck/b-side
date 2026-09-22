// swift-tools-version: 6.0
import PackageDescription

// Apple Silicon (arm64) only — the app is built and run locally, no Intel support intended.
let package = Package(
    name: "DashNative",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DashNative", targets: ["DashNative"]),
        .library(name: "DashNativeKit", targets: ["DashNativeKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // Pinned exactly, not a range: the embedding API is explicitly unstable
        // upstream (see docs/native-rewrite.md §12). Bumping this is a deliberate,
        // reviewed step, not an incidental `swift package update`.
        .package(url: "https://github.com/Lakr233/libghostty-spm", exact: "1.6.20260922"),
    ],
    targets: [
        .executableTarget(
            name: "DashNative",
            dependencies: ["DashNativeKit"]
        ),
        .target(
            name: "DashNativeKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ]
        ),
        .testTarget(
            name: "DashNativeKitTests",
            dependencies: ["DashNativeKit"]
        ),
    ]
)
