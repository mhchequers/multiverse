// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Multiverse",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "Multiverse",
            path: "Sources/Multiverse"
        ),
    ]
)
