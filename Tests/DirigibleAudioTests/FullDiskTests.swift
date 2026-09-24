import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Packages on a disk image: a full disk (criterion 18), a volume that goes away during a read,
/// and a read-only volume. Slow: each test makes and attaches a disk image. The disk work runs
/// off the main actor: under load it takes seconds, and the `@MainActor` record tests wait for
/// the main actor (the tdd skill). Only the two tests that open a Studio are `@MainActor`.
struct FullDiskTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    @MainActor func aTakeOnAFullDiskStaysPendingUntilARetryAfterSpaceIsFree() async throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "full.dmg")
        let volume = folder.url.appending(path: "volume")
        try await offMainActor {
            try Self.hdiutil("create", "-size", "20m", "-fs", "HFS+", "-volname", "DirigibleFull", image.path)
            try Self.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        }
        defer { try? Self.hdiutil("detach", volume.path, "-force") }

        let package = volume.appending(path: "Show.dirigible")
        let caf = package.appending(path: "Capture/take1-1-1.caf")
        let filler = volume.appending(path: "filler")
        let before = LockedBox<Data>()
        try await offMainActor {
            // 10 s of mono: a 1.92 MB CAF and a 1.44 MB WAV.
            let source = try TakePackage()
            try source.segment(samples: sine(seconds: 10, rate: 48_000))
            try FileManager.default.copyItem(at: source.url, to: package)
            before.value = try Data(contentsOf: caf)
            try Self.fill(volume, leaving: 400_000, with: filler)
        }
        let cafBytes = try #require(before.value)

        let studio = try await Studio.open(package)

        #expect(studio.pendingTake?.take == 1)
        guard case .finalize(.writeFailed(file: "Clips/take1-1-1.wav", _)) = studio.takeError else {
            Issue.record("Expected a WAV write error, got \(String(describing: studio.takeError))")
            return
        }
        #expect(try Data(contentsOf: caf) == cafBytes)

        try FileManager.default.removeItem(at: filler)
        try await studio.retryFinalize()

        #expect(studio.pendingTake == nil)
        #expect(studio.session.track("t1")?.clips.first?.length == 480_000)
    }

    /// The real shape of an I/O fault (probe 2026-09-24, probe-read-error.swift): the volume goes
    /// away before block 1, and AVAudioFile throws -40 with no errno. It is take-wide, not a bad file.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aCAFReadErrorWithNoErrnoIsTakeWide() throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "gone.dmg")
        let volume = folder.url.appending(path: "volume")
        try Self.hdiutil("create", "-size", "20m", "-fs", "HFS+", "-volname", "DirigibleGone", image.path)
        try Self.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        let package = volume.appending(path: "Show.dirigible")
        // The fault detaches the volume, so this detach can fail.
        defer { Self.run(["detach", volume.path, "-force"]) }
        // 10 s of mono: 8 blocks of 65,536 frames.
        let source = try TakePackage()
        try source.segment(samples: sine(seconds: 10, rate: 48_000))
        try FileManager.default.copyItem(at: source.url, to: package)
        let session = try Session(contentsOf: package)
        let detach = ReadFault(stem: "take1-1-1", block: 1) { try Self.hdiutil("detach", volume.path, "-force") }

        #expect(throws: FinalizeError.readFailed(file: "Capture/take1-1-1.caf", errno: EIO)) {
            try finalizeTake(of: session, in: package, readFault: detach)
        }
    }

    /// Decision 0012: a read-only volume opens without a lock, with and without a `.lock` file.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    @MainActor func aPackageOnAReadOnlyVolumeOpensUnlocked() async throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "readonly.dmg")
        let volume = folder.url.appending(path: "volume")
        try await offMainActor {
            try Self.hdiutil("create", "-size", "20m", "-fs", "HFS+", "-volname", "DirigibleReadOnly", image.path)
            try Self.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        }
        defer { Self.run(["detach", volume.path, "-force"]) }
        let names = ["New.dirigible", "Opened.dirigible"]
        try await offMainActor {
            for name in names { try Session(sampleRate: 48_000).write(to: volume.appending(path: name)) }
            try Data().write(to: volume.appending(path: "Opened.dirigible/.lock"))
            try Self.hdiutil("detach", volume.path)
            try Self.hdiutil("attach", image.path, "-readonly", "-nobrowse", "-mountpoint", volume.path)
        }

        for name in names {
            let studio = try await Studio.open(volume.appending(path: name))
            #expect(studio.session == Session(sampleRate: 48_000), "\(name)")
        }
    }

    /// A 10 s stereo render (3.84 MB) to a volume with 400 KB free throws and leaves no output
    /// and no temporary file (plan gate 1 item 5).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aRenderOnAFullDiskLeavesNoOutput() throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "full.dmg")
        let volume = folder.url.appending(path: "volume")
        try Self.hdiutil("create", "-size", "20m", "-fs", "HFS+", "-volname", "DirigibleRender", image.path)
        try Self.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        defer { Self.run(["detach", volume.path, "-force"]) }
        let package = try RenderMixTests.package()
        try Self.fill(volume, leaving: 400_000, with: volume.appending(path: "filler"))
        let out = volume.appending(path: "mix.caf")

        #expect(throws: RenderError.self) {
            try renderMix(package.session, package: package.url, range: 0..<480_000, to: out)
        }
        #expect(try Self.visibleFiles(volume) == ["filler"])
    }

    /// exFAT gives ENOTSUP for `renamex_np(RENAME_EXCL)` (probe X1), so the render claims the
    /// path and renames over the claim. A second render to that path changes nothing. An exFAT
    /// volume name has 11 characters or fewer.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aRenderToExFATClaimsAndRenames() throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "exfat.dmg")
        let volume = folder.url.appending(path: "volume")
        try Self.hdiutil("create", "-size", "20m", "-fs", "ExFAT", "-volname", "DirExFAT", image.path)
        try Self.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        defer { Self.run(["detach", volume.path, "-force"]) }
        let package = try RenderMixTests.package()
        let out = volume.appending(path: "mix.caf")

        _ = try renderMix(package.session, package: package.url, range: 0..<9600, to: out)
        let bytes = try Data(contentsOf: out)
        for (a, b) in zip(try RenderMixTests.read(out), try package.mix(0..<9600)) { #expect(maxError(a, b) <= 1e-6) }
        #expect(try Self.visibleFiles(volume) == ["mix.caf"])

        #expect(throws: RenderError.exists) {
            try renderMix(package.session, package: package.url, range: 0..<4800, to: out)
        }
        #expect(try Data(contentsOf: out) == bytes)
        #expect(try Self.visibleFiles(volume) == ["mix.caf"])
    }

    /// The files in `volume` with no leading dot (the system adds some), and every `.tmp` file.
    static func visibleFiles(_ volume: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: volume.path).filter {
            !$0.hasPrefix(".") || $0.hasSuffix(".tmp")
        }
        .sorted()
    }

    /// Writes zeros to `file` until the volume has about `bytes` free.
    static func fill(_ volume: URL, leaving bytes: Int, with file: URL) throws {
        let free = try #require(
            try FileManager.default.attributesOfFileSystem(forPath: volume.path)[.systemFreeSize] as? Int)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var left = free - bytes
        let chunk = Data(count: 1 << 20)
        while left > 0 {
            try handle.write(contentsOf: chunk.prefix(left))
            left -= chunk.count
        }
        try handle.synchronize()
    }

    static func hdiutil(_ arguments: String...) throws {
        try #require(run(arguments) == 0, "hdiutil \(arguments.joined(separator: " ")) failed")
    }

    /// Runs hdiutil and returns its exit status.
    @discardableResult
    static func run(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
