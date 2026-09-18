// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Vibestick",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Vibestick", targets: ["Vibestick"]),
        .library(name: "VibestickCore", targets: ["VibestickCore"]),
    ],
    targets: [
        .target(
            name: "VibestickCore",
            path: "Sources/VibestickCore"
        ),
        .executableTarget(
            name: "Vibestick",
            dependencies: ["VibestickCore"],
            path: "Sources/Vibestick"
        ),
        .testTarget(
            name: "VibestickCoreTests",
            dependencies: ["VibestickCore"],
            path: "Tests/VibestickCoreTests"
        ),
    ]
)
