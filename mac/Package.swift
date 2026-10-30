// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Sitch",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        // Document model, annotations, renderer and settings: no windows, no capture, so it is
        // unit-testable and shared by the editor and the headless --shot-region render.
        .target(
            name: "SitchCore",
            path: "Sources/SitchCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // The screenshot line, merged from the standalone Snapline app. Kept in the Swift 5
        // language mode it was written in; Sitch talks to it only through ShelfController.
        .target(
            name: "SitchShelf",
            path: "Sources/SitchShelf",
            exclude: ["Resources"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "Sitch",
            dependencies: ["SitchCore", "SitchShelf"],
            path: "Sources/Sitch",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SitchCoreTests",
            dependencies: ["SitchCore"],
            path: "Tests/SitchCoreTests"
        )
    ]
)
