import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// C6: a package that the job cannot lock or write keeps its CAF.
extension RawSweepTests {
    /// C6: a second open during the lock of the first gets `.locked` and removes nothing. The
    /// first studio then removes the CAF.
    @Test func aSecondOpenDuringAHeldLockIsLocked() async throws {
        let (package, _) = try await Self.oldTake()
        let (studio, hold, _) = try await Self.held(package, at: .block(2))
        defer { hold.gate.open() }

        await #expect(throws: StudioError.locked) { _ = try await Studio.open(package.url) }
        #expect(Self.hasCAF(package), "the second open removes nothing")
        hold.gate.open()
        await studio.rawSweep

        #expect(!Self.hasCAF(package), "the first studio removes the CAF")
        await studio.settle()
    }

    /// C6: a package on a read-only volume opens, with and without a lock file, and its CAF and
    /// sidecar do not change.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aReadOnlyPackageOpensAndKeepsItsCAF() async throws {
        let (package, _) = try await Self.oldTake()
        let sidecar = try Data(contentsOf: package.capture.appending(path: Self.segment.sidecarName))
        let folder = try TemporaryFolder()
        let (image, volume) = (folder.url.appending(path: "readonly.dmg"), folder.url.appending(path: "volume"))
        let (names, source) = (["Locked.dirigible", "Unlocked.dirigible"], package.url)
        try await offMainActor {
            try FullDiskTests.hdiutil("create", "-size", "20m", "-fs", "HFS+", "-volname", "RawReadOnly", image.path)
            try FullDiskTests.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        }
        defer { FullDiskTests.run(["detach", volume.path, "-force"]) }
        try await offMainActor {
            for name in names { try FileManager.default.copyItem(at: source, to: volume.appending(path: name)) }
            try? FileManager.default.removeItem(at: volume.appending(path: "Unlocked.dirigible/.lock"))
            try FullDiskTests.hdiutil("detach", volume.path)
            try FullDiskTests.hdiutil("attach", image.path, "-readonly", "-nobrowse", "-mountpoint", volume.path)
        }

        for name in names {
            let url = volume.appending(path: name)
            let studio = try await Studio.open(url)
            await studio.rawSweep
            let capture = url.appending(path: "Capture")
            let caf = capture.appending(path: Self.segment.cafName)
            #expect(FileManager.default.fileExists(atPath: caf.path), "\(name)")
            #expect(try Data(contentsOf: capture.appending(path: Self.segment.sidecarName)) == sidecar, "\(name)")
        }
    }
}
