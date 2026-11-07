import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// The follow alert and the window rules of Follow in Ripples (decision 0073, criteria C36, C39).
/// Fixture F: track `host` (h 0 ..< 960 000), track `bed` (follows, bed 0 ..< 960 000), and track
/// `sfx` (follows) with w at 192 000 (48 001 frames), x at 264 000 (12 000), and y at 360 000.
@Suite(.serialized) @MainActor struct FollowTrackAlertTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    static let cut: Range<Frames> = 240_000..<336_000

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
    }

    /// `wLength` 48 001 makes a ripple of `cut` refuse (x would cover w); 24 000 lets it pass (C32).
    func package(
        wLength: Frames = 48_001, follow: [TrackID] = ["bed", "sfx"], name: String = "f", pendingTake: Bool = false
    ) async throws -> URL {
        let url = folder.url.appending(path: "\(name).dirigible")
        try await Task.detached {
            try Session.create(at: url, sampleRate: 48_000)
            var session = Session(sampleRate: 48_000)
            for (track, name, file) in [("host", "Host", "h"), ("bed", "Bed", "b"), ("sfx", "Sfx", "s")] {
                try session.addTrack(TrackID(track), name: name, layout: .mono)
                try session.addFile(AudioFile(id: FileID(file), path: "\(file).wav", layout: .mono, length: 1_000_000))
            }
            try session.place(Clip(id: "h", file: "h", start: 0, offset: 0, length: 960_000), on: "host")
            try session.place(Clip(id: "bed", file: "b", start: 0, offset: 0, length: 960_000), on: "bed")
            for clip in [
                Clip(id: "w", file: "s", start: 192_000, offset: 0, length: wLength),
                Clip(id: "x", file: "s", start: 264_000, offset: 100_000, length: 12_000),
                Clip(id: "y", file: "s", start: 360_000, offset: 200_000, length: 48_000),
            ] { try session.place(clip, on: "sfx") }
            try session.setFollowTrack(true, tracks: follow)
            if pendingTake {
                try session.setRecording(
                    Recording(
                        take: 1, playheadFrame: 0, takeStartHostTimeNanos: 1_000_000_000_000, armedTracks: ["host"]))
            }
            try session.write(to: url)
        }.value
        return url
    }

    /// C39: the title, and the body with the track name and the time of the clip start. The tests
    /// read the English table, which `Bundle.main` lacks; the alert maps to the title key.
    @Test func theAlertTextNamesTheClipByTrackAndTime() throws {
        let english = try stringsTable("en")
        func overlap(_ seconds: Int) -> FollowOverlap {
            FollowOverlap(track: "t1", trackName: "Host", start: Frames(seconds * 48_000), rate: 48_000)
        }
        func table(_ key: L10n) -> String { english[key.rawValue] ?? key.rawValue }
        #expect(overlap(125).title(table: table) == "A clip would cover another clip.")
        #expect(
            overlap(125).body(locale: Locale(identifier: "en"), table: table)
                == "The clip on Host at 2:05 follows ripples. Move it, or turn off Follow in Ripples.")
        #expect(overlap(3_725).body(locale: Locale(identifier: "en"), table: table).contains("at 1:02:05 follows"))
        #expect(WindowAlert.followOverlap(overlap(125)).text == L10n.alertFollowOverlapTitle.text)
        #expect(WindowAlert.followOverlap(overlap(125)).message == overlap(125).body())
        #expect(WindowAlert.confirmStopAndClose.message == nil)
    }

    /// C36: a ripple that would cover a clip of a follow track sets the alert of that track at the
    /// start of the clip, and makes no undo entry. Another refusal keeps the error alert.
    @Test func aWindowRippleShowsTheFollowAlert() async throws {
        let (model, studio) = try await timelineModel(try await package(), app: app)
        let before = studio.session
        model.edit(ripple: true) { session throws(SessionError) in
            try session.rippleDelete([Self.cut], on: session.tracks.map(\.id), naming: [])
        }
        #expect(
            model.alert == .followOverlap(FollowOverlap(track: "sfx", trackName: "Sfx", start: 264_000, rate: 48_000)))
        #expect(studio.session == before && !studio.canUndo)

        model.alert = nil
        model.edit(ripple: true) { session throws(SessionError) in
            try session.rippleDelete([Self.cut], on: ["nope"], naming: [])
        }
        #expect(model.alert != nil)
        if case .followOverlap = model.alert { Issue.record("another refusal must keep the error alert") }
        await model.close()
    }

    /// A range on `host`, so the `edit(ripple:)` and Replace sites run with `sfx` in no selection and
    /// no paste target.
    func selectHost(_ model: SessionWindow) {
        model.timeline.selection = .range(Marks(inPoint: 240_000, outPoint: 336_000, tracks: ["host"]))
    }

    /// C36: Delete and Close Gap, Cut, and Replace each set the follow alert of `sfx` at the start of
    /// x, and make no undo entry. The Silences Apply site is in `SilencesInspectorTests`.
    @Test func eachWindowRippleShowsTheFollowAlert() async throws {
        let (model, studio) = try await timelineModel(try await package(), app: app)
        let alert = WindowAlert.followOverlap(
            FollowOverlap(track: "sfx", trackName: "Sfx", start: 264_000, rate: 48_000))
        let before = studio.session
        for command in [TimelineCommand.deleteCloseGap, .cut] {
            selectHost(model)
            model.run(command)
            #expect(model.alert == alert, "\(command)")
            #expect(studio.session == before && !studio.canUndo, "\(command)")
            model.alert = nil
        }

        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["host"])
        model.run(.copy)
        selectHost(model)
        model.run(.replace)
        await until("the run ends") { model.importJob == nil }
        #expect(model.alert == alert, "Replace")
        #expect(studio.session == before && !studio.canUndo, "Replace")
        await model.close()
    }

    /// C36: under a pending take, each ripple that would show the follow alert beeps instead, with no
    /// alert and no edit. The `Clips/` folder is read-only during the open, so the take stays pending.
    @Test func eachWindowRippleUnderAPendingTakeBeeps() async throws {
        let url = try await package(name: "pending", pendingTake: true)
        let clips = url.appending(path: "Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        chmod(clips.path, 0o500)
        let (model, studio) = try await timelineModel(url, app: app)
        chmod(clips.path, 0o755)
        try #require(studio.pendingTake?.take == 1)
        let before = studio.session
        var beeps = 0
        model.beep = { beeps += 1 }
        for command in [TimelineCommand.deleteCloseGap, .cut] {
            selectHost(model)
            model.run(command)
        }
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["host"])
        model.run(.copy)
        selectHost(model)
        model.run(.replace)
        #expect(beeps == 3 && model.alert == nil, "each ripple beeps")
        #expect(studio.session == before && !studio.canUndo)
        await model.close()
    }

    /// C39: Turn Off clears the flag of the named track only, as one undo entry, and does not run
    /// the ripple again.
    @Test func turnOffClearsTheFlagInOneUndoEntry() async throws {
        let (model, studio) = try await timelineModel(try await package(), app: app)
        model.edit(ripple: true) { session throws(SessionError) in
            try session.rippleDelete([Self.cut], on: session.tracks.map(\.id), naming: [])
        }
        let before = studio.session
        let alert = try #require(model.alert)
        model.turnOffFollow(in: alert)
        #expect(model.alert == nil)
        #expect(studio.session.tracks.filter(\.isFollowTrack).map(\.id) == ["bed"])
        #expect(studio.session.track("sfx")?.clips.map(\.range) == before.track("sfx")?.clips.map(\.range))
        try studio.undo()
        #expect(studio.session == before, "one undo gives back the session before Turn Off")
        await model.close()
    }
}
