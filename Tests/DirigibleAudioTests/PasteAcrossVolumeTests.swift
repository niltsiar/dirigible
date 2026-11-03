import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// A paste across volumes (decision 0042, C6 and C7b). Slow: each test makes and attaches an HFS+
/// disk image, so the paste copies the bytes: no clone.
struct PasteAcrossVolumeTests {
    /// 64 MB of mono 24-bit audio at 48 kHz.
    static let frames = 22_369_621

    /// A source package with one 64 MB file and one clip of it on track t1, in `folder`.
    static func source(in folder: URL) throws -> (url: URL, clipboard: Clipboard) {
        let package = try MixPackage()
        try package.addFile("take1-mic", channels: [sine(seconds: Double(frames) / 48_000, rate: 48_000)])
        try package.addTrack("t1", clip: "A", file: "take1-mic", start: 0, offset: 0, length: Frames(frames))
        let url = folder.appending(path: "Source.dirigible")
        try FileManager.default.copyItem(at: package.url, to: url)
        FileManager.default.createFile(atPath: url.appending(path: ".lock").path, contents: nil)
        let excerpt = try package.session.excerpt(of: 0..<Frames(frames), on: ["t1"])
        return (url, Clipboard(excerpt, package: url, origin: PackageID(lockFileOf: url)))
    }

    /// An empty target package with mono track u1 in `folder`.
    static func target(in folder: URL) throws -> (url: URL, session: Session) {
        let url = folder.appending(path: "Target.dirigible")
        try FileManager.default.createDirectory(
            at: url.appending(path: clipsFolderName), withIntermediateDirectories: true)
        var session = Session(sampleRate: 48_000)
        try session.addTrack("u1", name: "u1", layout: .mono)
        return (url, session)
    }

    static func names(_ package: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: package.appending(path: clipsFolderName).path).sorted()
    }

    /// C6: the bytes go across, the progress never goes down and ends at 1, and a cancel at the
    /// first progress call leaves no new name. Control: a callback that ignores the flag.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aCopyToAnotherVolumeReportsProgressAndCancels() async throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "source.dmg")
        let volume = folder.url.appending(path: "volume")
        try await offMainActor {
            try FullDiskTests.hdiutil(
                "create", "-size", "200m", "-fs", "HFS+", "-volname", "DirigiblePaste", image.path)
            try FullDiskTests.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        }
        defer { FullDiskTests.run(["detach", volume.path, "-force"]) }
        let (source, clipboard) = try Self.source(in: volume)
        let (target, session) = try Self.target(in: folder.url)
        let values = OSAllocatedUnfairLock<[Double]>(initialState: [])

        _ = try pasteClipboard(
            clipboard, from: source, into: session, in: target, identity: nil, mode: .over(at: 0), on: .tracks(["u1"]),
            freeBytes: { .max }, progress: { value in values.withLock { $0.append(value) } })

        let seen = values.withLock { $0 }
        #expect(seen.count > 10, "a copy calls back each 1 MB; a clone does not: \(seen.count)")
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 } && seen.last == 1)
        let copied = FileManager.default.contents(atPath: target.appending(path: "Clips/take1-mic.wav").path)
        let original = FileManager.default.contents(atPath: source.appending(path: "Clips/take1-mic.wav").path)
        #expect(copied != nil && copied == original)

        let (other, otherSession) = try Self.target(in: folder.url.appending(path: "other"))
        let last = OSAllocatedUnfairLock<Double?>(initialState: nil)
        #expect(throws: PasteError.cancelled) {
            try pasteClipboard(
                clipboard, from: source, into: otherSession, in: other, identity: nil, mode: .over(at: 0),
                on: .tracks(["u1"]),
                freeBytes: { .max }, progress: { value in last.withLock { $0 = value } },
                isCancelled: { last.withLock { $0 != nil } })
        }
        #expect(try Self.names(other).isEmpty, "no WAV and no .tmp")
        let stopped = last.withLock { $0 } ?? 1
        #expect(stopped < 0.5, "the copy stops at the next callback, not at its end: \(stopped)")
    }

    /// C7b: a target on a 20 MB image fills during the copy: the callback quits at `COPYFILE_ERR`,
    /// the paste throws ENOSPC within the time limit, and no `.tmp` stays. Control: a callback that
    /// continues at `COPYFILE_ERR` loops with no end (probe P1).
    @Test(.timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aFullDiskStopsTheCopy() async throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "target.dmg")
        let volume = folder.url.appending(path: "volume")
        try await offMainActor {
            try FullDiskTests.hdiutil("create", "-size", "20m", "-fs", "HFS+", "-volname", "DirigibleFull", image.path)
            try FullDiskTests.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        }
        defer { FullDiskTests.run(["detach", volume.path, "-force"]) }
        let (source, clipboard) = try Self.source(in: folder.url)
        let (target, session) = try Self.target(in: volume)

        #expect(throws: PasteError.write(file: "take1-mic.wav", errno: ENOSPC)) {
            try pasteClipboard(
                clipboard, from: source, into: session, in: target, identity: nil, mode: .over(at: 0),
                on: .tracks(["u1"]),
                freeBytes: { .max })
        }
        #expect(try Self.names(target).isEmpty, "no WAV and no .tmp")
    }

    /// Code gate 2 item 3: a file that the space check counts as a clone must clone. A source on
    /// another volume with `canClone` true fails with EXDEV and copies nothing. Controls: a clone
    /// flag that is always false, and a clone that falls back to a copy.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aCloneThatCannotCloneFailsWithNoCopy() async throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "clone.dmg")
        let volume = folder.url.appending(path: "volume")
        try await offMainActor {
            try FullDiskTests.hdiutil(
                "create", "-size", "200m", "-fs", "HFS+", "-volname", "DirigibleClone", image.path)
            try FullDiskTests.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        }
        defer { FullDiskTests.run(["detach", volume.path, "-force"]) }
        let (source, clipboard) = try Self.source(in: volume)
        let (target, session) = try Self.target(in: folder.url)

        #expect(throws: PasteError.write(file: "take1-mic.wav", errno: EXDEV)) {
            try pasteClipboard(
                clipboard, from: source, into: session, in: target, identity: nil, mode: .over(at: 0),
                on: .tracks(["u1"]),
                freeBytes: { 0 }, canClone: { _, _ in true })
        }
        #expect(try Self.names(target).isEmpty, "no WAV and no .tmp")
    }
}
