// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Multiverse",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(url: "https://github.com/smittytone/HighlighterSwift.git", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Multiverse",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Highlighter", package: "HighlighterSwift"),
            ],
            path: "Sources/Multiverse",
            resources: [.process("Resources")]
        ),
    ]
)
