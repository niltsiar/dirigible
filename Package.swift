// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dirigible",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DirigibleCore"),
        .executableTarget(name: "DirigibleApp", dependencies: ["DirigibleCore"]),
        .testTarget(name: "DirigibleCoreTests", dependencies: ["DirigibleCore"]),
        .testTarget(name: "DirigibleTests"),
    ]
)
