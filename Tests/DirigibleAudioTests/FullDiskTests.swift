import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A take on a full disk (criterion 18). Slow: it makes and attaches a 20 MB disk image.
@MainActor
struct FullDiskTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aTakeOnAFullDiskStaysPendingUntilARetryAfterSpaceIsFree() async throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "full.dmg")
        let volume = folder.url.appending(path: "volume")
        try hdiutil("create", "-size", "20m", "-fs", "HFS+", "-volname", "DirigibleFull", image.path)
        try hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        defer { try? hdiutil("detach", volume.path, "-force") }

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

    func hdiutil(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "hdiutil \(arguments.joined(separator: " ")) failed")
    }
}
