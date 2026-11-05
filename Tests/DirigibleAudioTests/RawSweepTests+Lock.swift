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
        defer { hold.open() }

        await #expect(throws: StudioError.locked) { _ = try await Studio.open(package.url) }
        #expect(Self.hasCAF(package), "the second open removes nothing")
        hold.open()
        await studio.rawSweep

        #expect(!Self.hasCAF(package), "the first studio removes the CAF")
        await studio.settle()
    }

    /// C6: a package that opens with no lock (no lock file in a package folder with no write
    /// access) keeps its CAF, also when `Capture/` takes the unlink.
    @Test func aPackageWithNoLockKeepsItsCAF() async throws {
        let (package, _) = try await Self.oldTake()
        try FileManager.default.removeItem(at: package.url.appending(path: ".lock"))
        try #require(chmod(package.url.path, 0o555) == 0)
        defer { chmod(package.url.path, 0o755) }
        let studio = try await Studio.open(package.url)
        try #require(!studio.lock.isHeld, "the package opens with no lock")

        await studio.rawSweep

        #expect(Self.hasCAF(package), "a package with no lock keeps its CAF")
        await studio.settle()
    }

    /// C6: a package on a read-only volume opens, with and without a lock file, and its CAF and
    /// sidecar do not change.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aReadOnlyPackageOpensAndKeepsItsCAF() async throws {
        let (package, _) = try await Self.oldTake()
        let sidecar = try Data(contentsOf: package.capture.appending(path: Self.segment.sidecarName))
        let names = ["Locked.dirigible", "Unlocked.dirigible"]
        try await Self.onReadOnlyVolume(names.map { ($0, package.url) }, unlocked: names[1]) { volume in
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

    /// C6: the removal of a locked edit, on a read-only volume where the lock file takes the lock,
    /// removes no CAF and writes no `raw` fault. On the writable volume the segment passes.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aLockedEditOnAReadOnlyVolumeRemovesNoCAF() async throws {
        let (package, record) = try await Self.oldTake()
        let sidecarURL = package.capture.appending(path: Self.segment.sidecarName)
        try #require(Sidecar.append(record, toSidecarAt: sidecarURL) == nil)
        let session = try package.read()
        let passes = removableCaptures(of: session, in: package.url).map(\.record) == [record]
        try #require(passes, "the segment with its record passes on the writable volume")
        let sidecar = try Data(contentsOf: sidecarURL)
        try await Self.onReadOnlyVolume([("Recorded.dirigible", package.url)]) { volume in
            let url = volume.appending(path: "Recorded.dirigible")
            var faults = 0
            try PackageLock.withLock(url, locked: { $0 }) { lock throws(SessionFileError) in
                #expect(lock.isHeld, "the lock file takes the lock on a read-only volume")
                removeRecordedRawCaptures(of: session, in: url) {
                    faults += 1
                    return .disabled
                }
            }
            let capture = url.appending(path: "Capture")
            #expect(faults == 0, "no raw fault")
            #expect(FileManager.default.fileExists(atPath: capture.appending(path: Self.segment.cafName).path))
            #expect(try Data(contentsOf: capture.appending(path: Self.segment.sidecarName)) == sidecar)
        }
    }

    /// Runs `body` with a read-only HFS+ volume that holds a copy of each package of `packages`
    /// under its name, with no lock file in the copy `unlocked`, and detaches the volume after it.
    static func onReadOnlyVolume(
        _ packages: [(name: String, source: URL)], unlocked: String? = nil, _ body: (URL) async throws -> Void
    ) async throws {
        let folder = try TemporaryFolder()
        let (image, volume) = (folder.url.appending(path: "readonly.dmg"), folder.url.appending(path: "volume"))
        try await offMainActor {
            try FullDiskTests.hdiutil("create", "-size", "20m", "-fs", "HFS+", "-volname", "RawReadOnly", image.path)
            try FullDiskTests.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        }
        // The folder holds the image, and its deinit removes it.
        defer { withExtendedLifetime(folder) { _ = FullDiskTests.run(["detach", volume.path, "-force"]) } }
        try await offMainActor {
            for (name, source) in packages {
                try FileManager.default.copyItem(at: source, to: volume.appending(path: name))
            }
            if let unlocked { try? FileManager.default.removeItem(at: volume.appending(path: "\(unlocked)/.lock")) }
            try FullDiskTests.hdiutil("detach", volume.path)
            try FullDiskTests.hdiutil("attach", image.path, "-readonly", "-nobrowse", "-mountpoint", volume.path)
        }
        try await body(volume)
    }
}
