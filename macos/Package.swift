// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MediaShuttle",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MediaShuttleCore", targets: ["MediaShuttleCore"]),
        .executable(name: "MediaShuttle", targets: ["MediaShuttle"])
    ],
    targets: [
        .target(
            name: "MediaShuttleCore",
            path: "Sources/MediaShuttleCore"
        ),
        .executableTarget(
            name: "MediaShuttle",
            dependencies: ["MediaShuttleCore"],
            path: "Sources/MediaShuttleApp"
        ),
        .testTarget(
            name: "MediaShuttleCoreTests",
            dependencies: ["MediaShuttleCore"],
            path: "Tests/MediaShuttleCoreTests"
        )
    ]
)
