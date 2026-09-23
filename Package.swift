// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dirigible",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Dirigible"),
        .testTarget(name: "DirigibleTests"),
    ]
)
