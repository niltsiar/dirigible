import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Edits and retries while a take waits for finalize (criteria 9, 10, and 19).
@MainActor
struct PendingTakeTests {
    let package: TakePackage
    var clips: URL { package.url.appending(path: "Clips") }
    var marker: URL { package.url.appending(path: "recovery-attempt") }

    /// `t1` and `t2` are armed, each with a closed 2.0 s segment. `t3` is not armed.
    init() throws {
        package = try TakePackage(tracks: [("t1", .mono), ("t2", .mono)])
        try package.segment(arm: 1, samples: sine(seconds: 2, rate: 48_000))
        try package.segment(arm: 2, samples: sine(seconds: 2, rate: 48_000, frequency: 500))
        var session = try package.read()
        try session.addTrack("t3", name: "Music", layout: .mono)
        try session.write(to: package.url)
    }

    /// Opens the package with `Clips/` at mode 0500, so finalize throws and the take stays
    /// pending. `Clips/` is writable again when this returns.
    func openPending() async throws -> Studio {
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        chmod(clips.path, 0o500)
        defer { chmod(clips.path, 0o755) }
        let studio = try await Studio.open(package.url)
        try #require(studio.pendingTake?.take == 1)
        return studio
    }

    @Test func anEditOfAnUnarmedTrackWorksAndTheSaveKeepsTheRecording() async throws {
        let studio = try await openPending()

        try studio.edit { session throws(SessionError) in try session.renameTrack("t3", to: "Jingle") }
        await studio.settle()

        let saved = try package.read()
        #expect(saved.track("t3")?.name == "Jingle")
        #expect(saved.recording?.take == 1)
        #expect(studio.canUndo)
    }

    @Test func anEditOfAnArmedTrackThrows() async throws {
        let studio = try await openPending()
        let before = studio.session

        #expect(throws: StudioError.session(.trackInRecording("t1"))) {
            try studio.edit { session throws(SessionError) in try session.removeTrack("t1") }
        }
        #expect(studio.session == before)
        #expect(!studio.canUndo)
    }

    /// Decision 0037: Studio refuses a declared ripple under a pending take, and only a ripple.
    /// Controls m1, m3, and m4.
    @Test func aRippleEditThrowsUnderAPendingTake() async throws {
        let studio = try await openPending()
        let before = studio.session

        #expect(throws: StudioError.rippleBlocked) {
            try studio.edit(ripple: true) { session throws(SessionError) in try session.renameTrack("t3", to: "J") }
        }
        #expect(
            studio.session == before && !studio.canUndo,
            "RIPPLE-S1 a ripple edit under a pending take changed the session")
        let renamed: Void? = try? studio.edit { session throws(SessionError) in try session.renameTrack("t3", to: "J") }
        #expect(renamed != nil, "RIPPLE-S5 a non-ripple edit under a pending take works")
    }

    /// Control m2: a ripple check that refuses with no take.
    @Test func aRippleEditWithNoTakeRuns() async throws {
        var session = try package.read()
        try session.setRecording(nil)
        try session.write(to: package.url)
        let studio = try await Studio.open(package.url)

        try? studio.edit(ripple: true) { session throws(SessionError) in try session.renameTrack("t3", to: "J") }

        #expect(studio.canUndo, "RIPPLE-S2 a ripple edit with no take runs")
    }

    @Test func aRetryWithWritableClipsPlacesTheTake() async throws {
        let studio = try await openPending()

        try await studio.retryFinalize()

        #expect(studio.pendingTake == nil)
        #expect(studio.takeError == nil)
        #expect(studio.session.tracks.map(\.clips.count) == [1, 1, 0])
        #expect(try package.read() == studio.session)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(studio.canUndo)

        try studio.undo()
        #expect(studio.session.tracks.map(\.clips.count) == [0, 0, 0])
        #expect(studio.session.recording == nil)
    }

    @Test func aRetryWithReadOnlyClipsThrowsAndStaysPending() async throws {
        let studio = try await openPending()
        chmod(clips.path, 0o500)
        defer { chmod(clips.path, 0o755) }

        // -54 is permErr, the ExtAudioFile status for a folder with no write access.
        let error = StudioError.finalize(.writeFailed(file: "Clips/take1-1-1.wav", status: -54))
        await #expect(throws: error) { try await studio.retryFinalize() }
        #expect(studio.pendingTake?.take == 1)
        #expect(studio.takeError == error)
    }

    @Test func aRetryWhoseSaveFailsThrowsAndStaysPending() async throws {
        let studio = try await openPending()
        // A non-empty folder in place of session.xml fails only the rename of the save.
        let xml = package.url.appending(path: "session.xml")
        try FileManager.default.removeItem(at: xml)
        try FileManager.default.createDirectory(at: xml, withIntermediateDirectories: false)
        FileManager.default.createFile(atPath: xml.appending(path: "x").path, contents: nil)

        await #expect {
            try await studio.retryFinalize()
        } throws: { error in
            guard case .file = error as? StudioError else { return false }
            return true
        }
        #expect(studio.pendingTake?.take == 1)
        guard case .file = studio.takeError else {
            Issue.record("Expected a file error, got \(String(describing: studio.takeError))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(studio.session.files.isEmpty)
    }

    @Test func aRetryWithNoPendingTakeDoesNothing() async throws {
        var session = try package.read()
        try session.setRecording(nil)
        try session.write(to: package.url)
        let studio = try await Studio.open(package.url)
        let before = studio.session

        try await studio.retryFinalize()

        #expect(studio.session == before)
        #expect(!studio.canUndo)
    }

    @Test func aRetryLeavesASegmentWithABadSidecarUnplaced() async throws {
        let studio = try await openPending()
        let handle = try FileHandle(forWritingTo: package.capture.appending(path: "take1-1-1.sidecar"))
        try handle.write(contentsOf: Data("XXXXXXXX".utf8))
        try handle.close()

        try await studio.retryFinalize()

        #expect(studio.pendingTake == nil)
        #expect(studio.takeError == nil)
        #expect(studio.session.track("t2")?.clips.map(\.id) == ["take1-2-1"])
        #expect(try package.read().recording == nil)
        #expect(studio.unplacedSegments.map(\.stem) == ["take1-1-1"])
    }
}
