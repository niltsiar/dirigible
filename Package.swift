// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dirigible",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "dirigible", targets: ["DirigibleCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.0"),
        .package(url: "https://github.com/apple/swift-atomics", from: "1.2.0"),
    ],
    targets: [
        .target(name: "DirigibleCore"),
        .target(
            name: "DirigibleAudio",
            dependencies: ["DirigibleCore", .product(name: "Atomics", package: "swift-atomics")]),
        .executableTarget(name: "DirigibleApp", dependencies: ["DirigibleCore"]),
        .executableTarget(
            name: "DirigibleCLI",
            dependencies: [
                "DirigibleCore", "DirigibleAudio", .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(name: "DirigibleCoreTests", dependencies: ["DirigibleCore"]),
        .testTarget(name: "DirigibleAudioTests", dependencies: ["DirigibleAudio", "DirigibleCore"]),
        .testTarget(name: "DirigibleCLITests", dependencies: ["DirigibleCLI", "DirigibleCore", "DirigibleAudio"]),
        .testTarget(name: "DirigibleTests"),
    ]
)
