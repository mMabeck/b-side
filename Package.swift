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
            ]
        ),
        .testTarget(
            name: "DashNativeKitTests",
            dependencies: ["DashNativeKit"]
        ),
    ]
)
