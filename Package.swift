// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Vibestick",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Vibestick", targets: ["Vibestick"]),
    ],
    targets: [
        .executableTarget(
            name: "Vibestick",
            path: "Sources/Vibestick"
        ),
    ]
)
