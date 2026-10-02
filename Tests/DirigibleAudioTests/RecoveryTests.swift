import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Recovery at `Studio.open`: one test for each row of the open table in the run design
/// (criteria 4 to 8, 19 to 21, 26, 28). Each test calls `Studio.open` from the main actor;
/// `openPackage` and `completeTake` check that they do not run on the main queue.
@MainActor
struct RecoveryTests {
    let package: TakePackage
    var marker: URL { package.url.appending(path: "recovery-attempt") }
    var sessionXML: URL { package.url.appending(path: "session.xml") }

    init() throws { package = try TakePackage() }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func bytes(_ paths: [String]) throws -> [Data] {
        try paths.map { try Data(contentsOf: package.url.appending(path: $0)) }
    }

    /// A package with `t1` and `t2` and a closed 2.0 s segment on each.
    func twoTrackPackage() throws -> TakePackage {
        let package = try TakePackage(tracks: [("t1", .mono), ("t2", .mono)])
        try package.segment(arm: 1, samples: sine(seconds: 2, rate: 48_000))
        try package.segment(arm: 2, samples: sine(seconds: 2, rate: 48_000, frequency: 500))
        return package
    }

    @Test func aPackageWithNoRecordingOpensIdle() async throws {
        var session = try package.read()
        try session.setRecording(nil)
        try session.write(to: package.url)

        let studio = try await Studio.open(package.url)

        #expect(studio.session == session)
        #expect(studio.transport == .idle)
        #expect(studio.pendingTake == nil)
        #expect(studio.takeError == nil)
        #expect(studio.unplacedSegments == [])
    }

    @Test func aStaleMarkerWithNoRecordingIsDeleted() async throws {
        var session = try package.read()
        try session.setRecording(nil)
        try session.write(to: package.url)
        FileManager.default.createFile(atPath: marker.path, contents: nil)

        _ = try await Studio.open(package.url)

        #expect(!exists(marker))
    }

    @Test func aRecordingWithAMarkerStaysPendingWithNoFinalize() async throws {
        try package.segment(samples: sine(seconds: 2, rate: 48_000))
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        let before = try Data(contentsOf: sessionXML)

        let studio = try await Studio.open(package.url)

        #expect(studio.pendingTake?.take == 1)
        #expect(studio.takeError == nil)
        #expect(studio.session.files.isEmpty)
        #expect(try Data(contentsOf: sessionXML) == before)
        #expect(!exists(package.url.appending(path: "Clips/take1-1-1.wav")))
    }

    @Test func aRecordingWithNoMarkerIsRecovered() async throws {
        // The writer stays open: the state of a crash during the take.
        let writer = try package.segment(samples: sine(seconds: 2, rate: 48_000), open: true)

        let studio = try await Studio.open(package.url)

        #expect(studio.pendingTake == nil)
        #expect(studio.takeError == nil)
        #expect(
            studio.session.track("t1")?.clips.first
                == Clip(id: "take1-1-1", file: "take1-1-1", start: 96_432, offset: 0, length: 96_000))
        #expect(try package.read() == studio.session)
        #expect(try package.read().recording == nil)
        #expect(!exists(marker))
        #expect(try readAudio(package.url.appending(path: "Clips/take1-1-1.wav")).samples.count == 96_000)
        withExtendedLifetime(writer) {}
    }

    /// The recovery uses the finalize of a take, so a peak of 1.5 gets the same clip gain (A11).
    @Test func aRecoveredSegmentOverFullScaleGetsTheClipGain() async throws {
        let writer = try package.segment(samples: sine(seconds: 2, rate: 48_000).map { $0 * 3 }, open: true)

        let studio = try await Studio.open(package.url)

        let gain = try #require(studio.session.track("t1")?.clips.first).gain.dB
        #expect(abs(gain - 3.5218) < 0.001)
        #expect(try package.read() == studio.session)
        withExtendedLifetime(writer) {}
    }

    @Test func aFinalizeThatThrowsKeepsTheTakePendingAndTheFilesUnchanged() async throws {
        try package.segment(samples: sine(seconds: 2, rate: 48_000))
        let clips = package.url.appending(path: "Clips")
        chmod(clips.path, 0o500)
        defer { chmod(clips.path, 0o755) }
        let files = ["session.xml", "Capture/take1-1-1.caf", "Capture/take1-1-1.sidecar"]
        let before = try bytes(files)

        var studio: Studio? = try await Studio.open(package.url)

        #expect(studio?.pendingTake?.take == 1)
        guard case .finalize(.writeFailed(file: "Clips/take1-1-1.wav", _)) = studio?.takeError else {
            Issue.record("Expected a WAV write error, got \(String(describing: studio?.takeError))")
            return
        }
        #expect(!exists(marker))
        #expect(try bytes(files) == before)

        studio = nil
        chmod(clips.path, 0o755)
        let control = try await Studio.open(package.url)
        #expect(control.pendingTake == nil)
    }

    @Test func aCAFThatDoesNotOpenKeepsTheWholeTakePending() async throws {
        let package = try twoTrackPackage()
        let caf = package.capture.appending(path: "take1-1-1.caf")
        chmod(caf.path, 0o000)
        defer { chmod(caf.path, 0o644) }

        var studio: Studio? = try await Studio.open(package.url)

        #expect(studio?.pendingTake?.take == 1)
        #expect(
            studio?.takeError
                == .finalize(
                    .segmentUnreadable(SegmentName(stem: "take1-1-1")!, file: "Capture/take1-1-1.caf", errno: EACCES)))
        #expect(studio?.session.track("t2")?.clips.isEmpty == true)

        studio = nil
        chmod(caf.path, 0o644)
        let control = try await Studio.open(package.url)
        #expect(control.session.tracks.map(\.clips.count) == [1, 1])
    }

    @Test func aBadSidecarLeavesItsSegmentUnplacedAcrossOpens() async throws {
        let package = try twoTrackPackage()
        let handle = try FileHandle(forWritingTo: package.capture.appending(path: "take1-1-1.sidecar"))
        try handle.write(contentsOf: Data("XXXXXXXX".utf8))
        try handle.close()

        var studio: Studio? = try await Studio.open(package.url)

        #expect(studio?.pendingTake == nil)
        #expect(studio?.takeError == nil)
        #expect(studio?.session.track("t2")?.clips.map(\.id) == ["take1-2-1"])
        #expect(studio?.unplacedSegments.map(\.stem) == ["take1-1-1"])
        studio = nil

        let saved = try Data(contentsOf: package.url.appending(path: "session.xml"))
        let again = try await Studio.open(package.url)
        #expect(again.unplacedSegments.map(\.stem) == ["take1-1-1"])
        #expect(again.session.recording == nil)
        #expect(try Data(contentsOf: package.url.appending(path: "session.xml")) == saved)
    }

    @Test func aMarkerThatCannotBeWrittenSkipsFinalize() async throws {
        try package.segment(samples: sine(seconds: 2, rate: 48_000))
        FileManager.default.createFile(atPath: package.url.appending(path: ".lock").path, contents: nil)
        chmod(package.url.path, 0o500)
        defer { chmod(package.url.path, 0o755) }

        let studio = try await Studio.open(package.url)

        #expect(studio.pendingTake?.take == 1)
        guard case .file = studio.takeError else {
            Issue.record("Expected a file error, got \(String(describing: studio.takeError))")
            return
        }
        #expect(!exists(package.url.appending(path: "Clips/take1-1-1.wav")))
    }

    @Test func aCrashAfterTheMarkerDeleteGivesTheSameSessionAsOneRun() async throws {
        try package.segment(samples: sine(seconds: 2, rate: 48_000))
        // The first run wrote the WAV and died before the save. One WAV is cut to half.
        let clean = try finalizeTake(of: package.read(), in: package.url)
        let wav = package.url.appending(path: "Clips/take1-1-1.wav")
        let wavBytes = try Data(contentsOf: wav)
        try wavBytes.prefix(wavBytes.count / 2).write(to: wav)

        let studio = try await Studio.open(package.url)

        #expect(studio.session == clean)
        #expect(try Data(contentsOf: wav) == wavBytes)
    }

    @Test func aLeftoverTemporaryFileIsDeleted() async throws {
        let leftover = package.url.appending(path: ".session.xml.\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: leftover.path, contents: Data("x".utf8))

        _ = try await Studio.open(package.url)

        #expect(!exists(leftover))
    }

    @Test func anUnreadableSessionFileThrows() async throws {
        try Data("not xml".utf8).write(to: sessionXML)

        await #expect(throws: StudioError.file(.malformedXML)) { try await Studio.open(package.url) }
    }

    @Test func aLockedPackageThrowsUntilTheStudioGoesAway() async throws {
        var studio: Studio? = try await Studio.open(package.url)

        await #expect(throws: StudioError.locked) { try await Studio.open(package.url) }
        #expect(studio != nil)
        studio = nil
        await #expect(throws: Never.self) { try await Studio.open(package.url) }
    }
}
