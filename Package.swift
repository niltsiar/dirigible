// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dirigible",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "dirigible", targets: ["DirigibleCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.0")
    ],
    targets: [
        .target(name: "DirigibleCore"),
        .executableTarget(name: "DirigibleApp", dependencies: ["DirigibleCore"]),
        .executableTarget(
            name: "DirigibleCLI",
            dependencies: ["DirigibleCore", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(name: "DirigibleCoreTests", dependencies: ["DirigibleCore"]),
        .testTarget(name: "DirigibleCLITests", dependencies: ["DirigibleCLI", "DirigibleCore"]),
        .testTarget(name: "DirigibleTests"),
    ]
)
