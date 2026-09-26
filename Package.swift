// swift-tools-version: 6.2
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
        .target(name: "DirigibleTimeline", dependencies: ["DirigibleCore"]),
        .executableTarget(
            name: "DirigibleApp", dependencies: ["DirigibleCore", "DirigibleAudio", "DirigibleTimeline"]),
        .executableTarget(
            name: "DirigibleCLI",
            dependencies: [
                "DirigibleCore", "DirigibleAudio", .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(name: "DirigibleCoreTests", dependencies: ["DirigibleCore"]),
        .testTarget(name: "DirigibleAudioTests", dependencies: ["DirigibleAudio", "DirigibleCore"]),
        .testTarget(name: "DirigibleCLITests", dependencies: ["DirigibleCLI", "DirigibleCore", "DirigibleAudio"]),
        .testTarget(name: "DirigibleTimelineTests", dependencies: ["DirigibleTimeline", "DirigibleCore"]),
        .testTarget(
            name: "DirigibleTests",
            dependencies: ["DirigibleApp", "DirigibleAudio", "DirigibleCore", "DirigibleTimeline"]),
    ]
)

// A warning in a target of this package is an error. Fix it at its cause. The settings of a
// dependency stay its own. scripts/check-warnings.sh checks this loop.
for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [.treatAllWarnings(as: .error)]
}
