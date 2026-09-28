// swift-tools-version: 6.2
import PackageDescription

// Apple Silicon (arm64) only — the app is built and run locally, no Intel support intended.
let package = Package(
    name: "BSide",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "BSide", targets: ["BSide"]),
        .library(name: "BSideKit", targets: ["BSideKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // Pinned exactly, not a range: the embedding API is explicitly unstable
        // upstream (see docs/native-rewrite.md §12). Bumping this is a deliberate,
        // reviewed step, not an incidental `swift package update`.
        .package(url: "https://github.com/Lakr233/libghostty-spm", exact: "1.6.20260922"),
        // highlight.js via JavaScriptCore, no WebView — used to colour the Changes diff.
        .package(url: "https://github.com/appstefan/HighlightSwift", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "BSide",
            dependencies: ["BSideKit"]
        ),
        .target(
            name: "BSideKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
                .product(name: "HighlightSwift", package: "HighlightSwift"),
            ]
        ),
        .testTarget(
            name: "BSideKitTests",
            dependencies: [
                "BSideKit",
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
                .product(name: "HighlightSwift", package: "HighlightSwift"),
            ]
        ),
    ]
)
