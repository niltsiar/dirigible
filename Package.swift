// swift-tools-version: 6.2
import PackageDescription

// The defines of a CPU build of whisper.cpp with Accelerate, as its CMake files set them
// (decision 0065).
let whisperDefines: [(name: String, value: String?)] = [
    ("_XOPEN_SOURCE", "600"), ("_DARWIN_C_SOURCE", nil), ("GGML_SCHED_MAX_COPIES", "4"), ("GGML_USE_CPU", nil),
    ("GGML_USE_BLAS", nil), ("GGML_USE_ACCELERATE", nil), ("GGML_BLAS_USE_ACCELERATE", nil),
    ("ACCELERATE_NEW_LAPACK", nil), ("ACCELERATE_LAPACK_ILP64", nil), ("GGML_USE_CPU_REPACK", nil),
    ("WHISPER_VERSION", "\"1.9.5\""),
]
let whisperHeaderPaths = ["src", "ggml/src", "ggml/src/ggml-cpu"]
let whisperC: [CSetting] =
    whisperDefines.map { .define($0.name, to: $0.value) } + whisperHeaderPaths.map { .headerSearchPath($0) }
    + [.treatAllWarnings(as: .error)]
let whisperCXX: [CXXSetting] =
    whisperDefines.map { .define($0.name, to: $0.value) } + whisperHeaderPaths.map { .headerSearchPath($0) }
    + [.treatAllWarnings(as: .error)]

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
        // LAME 4.0 libmp3lame, with no decoder (decisions 0007 and 0034).
        .target(
            name: "CLame", exclude: ["README.dirigible"],
            cSettings: [.define("HAVE_CONFIG_H"), .headerSearchPath("."), .treatAllWarnings(as: .error)]),
        // The main-thread stack walk and the image list of the hang watchdog (decision 0059).
        .target(name: "CMainStack", cSettings: [.treatAllWarnings(as: .error)]),
        // whisper.cpp v1.9.5 and its ggml for the CPU, and the stop flag of a transcription
        // (decision 0065). The arch wrapper files build the arch folder; README.dirigible lists the patch.
        .target(
            name: "CWhisper",
            exclude: ["LICENSE", "README.dirigible", "ggml/src/ggml-cpu/arch", "src/aneforge/whisper-aneforge.cpp"],
            cSettings: whisperC, cxxSettings: whisperCXX, linkerSettings: [.linkedFramework("Accelerate")]),
        .target(
            name: "DirigibleAudio",
            dependencies: [
                "DirigibleCore", "CLame", "CMainStack", "CWhisper", .product(name: "Atomics", package: "swift-atomics"),
            ]),
        .target(name: "DirigibleTimeline", dependencies: ["DirigibleCore"]),
        .target(name: "DirigibleMCP", dependencies: ["DirigibleCore", "DirigibleAudio"]),
        .executableTarget(
            name: "DirigibleApp",
            dependencies: ["DirigibleCore", "DirigibleAudio", "DirigibleTimeline", "DirigibleMCP"]),
        .executableTarget(
            name: "DirigibleCLI",
            dependencies: [
                "DirigibleCore", "DirigibleAudio", "DirigibleMCP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(name: "DirigibleCoreTests", dependencies: ["DirigibleCore"]),
        .testTarget(
            name: "DirigibleAudioTests", dependencies: ["DirigibleAudio", "DirigibleCore", "CMainStack", "CWhisper"],
            exclude: ["Fixtures"]),
        .testTarget(
            name: "DirigibleCLITests",
            dependencies: ["DirigibleCLI", "DirigibleMCP", "DirigibleCore", "DirigibleAudio"],
            exclude: ["Fixtures"]),
        .testTarget(name: "DirigibleMCPTests", dependencies: ["DirigibleMCP", "DirigibleAudio", "DirigibleCore"]),
        .testTarget(name: "DirigibleTimelineTests", dependencies: ["DirigibleTimeline", "DirigibleCore"]),
        .testTarget(
            name: "DirigibleTests",
            dependencies: ["DirigibleApp", "DirigibleAudio", "DirigibleCore", "DirigibleTimeline", "DirigibleMCP"]),
    ],
    cxxLanguageStandard: .cxx17
)

// A Swift warning in a target of this package is an error. Fix it at its cause. A C target states
// the same setting in its cSettings. The settings of a dependency stay its own.
// scripts/check-warnings.sh checks this loop and each C target.
for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [.treatAllWarnings(as: .error)]
}
