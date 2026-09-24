import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Takes on a disk image: a full disk (criterion 18) and a volume that goes away during a read.
/// Slow: each test makes and attaches a disk image.
@MainActor
struct FullDiskTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aTakeOnAFullDiskStaysPendingUntilARetryAfterSpaceIsFree() async throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "full.dmg")
        let volume = folder.url.appending(path: "volume")
        try Self.hdiutil("create", "-size", "20m", "-fs", "HFS+", "-volname", "DirigibleFull", image.path)
        try Self.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        defer { try? Self.hdiutil("detach", volume.path, "-force") }

        // 10 s of mono: a 1.92 MB CAF and a 1.44 MB WAV.
        let source = try TakePackage()
        try source.segment(samples: sine(seconds: 10, rate: 48_000))
        let package = volume.appending(path: "Show.dirigible")
        try FileManager.default.copyItem(at: source.url, to: package)
        let caf = package.appending(path: "Capture/take1-1-1.caf")
        let cafBytes = try Data(contentsOf: caf)
        let filler = volume.appending(path: "filler")
        try fill(volume, leaving: 400_000, with: filler)

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

    /// Writes zeros to `file` until the volume has about `bytes` free.
    func fill(_ volume: URL, leaving bytes: Int, with file: URL) throws {
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

    nonisolated static func hdiutil(_ arguments: String...) throws {
        try #require(run(arguments) == 0, "hdiutil \(arguments.joined(separator: " ")) failed")
    }

    /// Runs hdiutil and returns its exit status.
    @discardableResult
    nonisolated static func run(_ arguments: [String]) -> Int32 {
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
