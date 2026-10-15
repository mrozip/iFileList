// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileIndexKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FileIndexKit", targets: ["FileIndexKit"]),
    ],
    targets: [
        .target(
            name: "FileIndexKit",
            // Search, sorting and scanning loop over millions of entries; unoptimized Debug
            // builds are too slow to use, so this target is always optimized.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "FileIndexKitTests",
            dependencies: ["FileIndexKit"]
        ),
    ]
)
