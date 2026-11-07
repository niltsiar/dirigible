import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// The lanes that a window cut names and the lanes that follow (decision 0073, criteria C51, C54,
/// C55, C56), on the fixture of `FollowTrackAlertTests` with `w` of 24 000 frames, so the ripple
/// passes: `host` and `bed` are 960 000 frames long, and `sfx` has w, x, and y.
extension FollowTrackAlertTests {
    func lane(_ studio: Studio, _ track: TrackID) -> [Range<Frames>] {
        studio.session.track(track)?.clips.map(\.range) ?? []
    }

    /// A ruler drag or I and O with no selected track: the range on all tracks by default.
    func rulerRange(_ session: Session) -> Selection {
        .range(
            Marks(
                inPoint: Self.cut.lowerBound, outPoint: Self.cut.upperBound, tracks: Set(session.tracks.map(\.id)),
                tracksByDefault: true))
    }

    /// The sfx lane after the cut with the C32 values: w stays, x goes to 240 000, y to 264 000.
    static let sfxAfter: [Range<Frames>] = [192_000..<216_000, 240_000..<252_000, 264_000..<312_000]
    static let cutLane: [Range<Frames>] = [0..<240_000, 240_000..<864_000]

    /// C51 window part: Cut in Selected Tracks with the range on `bed` removes the range from the bed
    /// and puts it on the clipboard. `host` and `sfx` stay.
    @Test func cutInSelectedTracksOnAFollowTrackRemovesTheRange() async throws {
        let (model, studio) = try await timelineModel(try await package(wLength: 24_000), app: app)
        let before = studio.session
        model.timeline.selection = .range(Marks(inPoint: 240_000, outPoint: 336_000, tracks: ["bed"]))

        model.run(.cutSelectedTracks)

        #expect(lane(studio, "bed") == Self.cutLane)
        #expect(lane(studio, "host") == lane(before, "host") && lane(studio, "sfx") == lane(before, "sfx"))
        let excerpt = try #require(app.clipboard?.excerpt)
        #expect(excerpt.lanes.map(\.source) == ["bed"] && excerpt.length == 96_000)
        await model.close()
    }

    func lane(_ session: Session, _ track: TrackID) -> [Range<Frames>] {
        session.track(track)?.clips.map(\.range) ?? []
    }

    /// C51 window part: after a ruler drag with no selected track the bed stays one clip and the
    /// speech closes up; a range drawn on the `bed` lane cuts the bed. `sfx` gets the C32 values in
    /// both.
    @Test func aRulerRangeLetsTheBedFollowAndALaneRangeCutsIt() async throws {
        let (model, studio) = try await timelineModel(try await package(wLength: 24_000), app: app)
        let before = studio.session
        model.timeline.selection = rulerRange(before)

        model.run(.deleteCloseGap)

        #expect(lane(studio, "host") == Self.cutLane)
        #expect(lane(studio, "bed") == [0..<960_000] && studio.session.track("bed")?.clips.map(\.id) == ["bed"])
        #expect(lane(studio, "sfx") == Self.sfxAfter)
        model.undo()
        try #require(studio.session == before)

        model.timeline.selection = .range(Marks(inPoint: 240_000, outPoint: 336_000, tracks: ["bed"]))
        model.run(.deleteCloseGap)

        #expect(lane(studio, "bed") == Self.cutLane)
        #expect(lane(studio, "host") == Self.cutLane)
        #expect(lane(studio, "sfx") == Self.sfxAfter)
        await model.close()
    }

    /// C54 window part: the excerpt of a Cut after a ruler drag holds the `host` lane only. With the
    /// flag off on `bed` and `sfx` it holds all three, as before.
    @Test func aCutOfARulerRangeCopiesOnlyTheLanesThatCut() async throws {
        let (model, studio) = try await timelineModel(try await package(wLength: 24_000), app: app)
        model.timeline.selection = rulerRange(studio.session)

        model.run(.cut)

        let excerpt = try #require(app.clipboard?.excerpt)
        #expect(excerpt.lanes.map(\.source) == ["host"] && excerpt.length == 96_000)
        await model.close()

        let (plain, studio2) = try await timelineModel(
            try await package(wLength: 24_000, follow: [], name: "g"), app: app)
        plain.timeline.selection = rulerRange(studio2.session)
        plain.run(.cut)
        #expect(app.clipboard?.excerpt.lanes.map(\.source) == ["host", "bed", "sfx"])
        await plain.close()
    }

    /// C55 window part: when each track follows and none is named, the ripple shows the error with the
    /// text of `error.ripple.follow.only`, makes no undo entry, and keeps the clipboard. A range
    /// drawn on `host` cuts it.
    @Test func aRippleOfOnlyFollowTracksShowsTheError() async throws {
        let (model, studio) = try await timelineModel(
            try await package(wLength: 24_000, follow: ["host", "bed", "sfx"]), app: app)
        let before = studio.session
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["sfx"])
        model.run(.copy)
        let clipboard = app.clipboard
        model.timeline.selection = rulerRange(before)

        for command in [TimelineCommand.deleteCloseGap, .cut] {
            model.run(command)
            #expect(model.alert == .error(.session(.noRippleTrack)), "\(command)")
            #expect(model.alert?.text == L10n.errorRippleFollowOnly.text, "\(command)")
            #expect(studio.session == before && !studio.canUndo && app.clipboard == clipboard, "\(command)")
            model.alert = nil
        }

        model.timeline.selection = .range(Marks(inPoint: 240_000, outPoint: 336_000, tracks: ["host"]))
        model.run(.deleteCloseGap)
        #expect(lane(studio, "host") == Self.cutLane && model.alert == nil)
        await model.close()
    }

    /// Fixture G: `bed` first (follows, one clip) and `host` second (no flag, one clip), both
    /// 960 000 frames.
    func packageG() async throws -> URL {
        let url = folder.url.appending(path: "g2.dirigible")
        try await Task.detached {
            try Session.create(at: url, sampleRate: 48_000)
            var session = Session(sampleRate: 48_000)
            for (track, name, file, clip) in [("bed", "Bed", "b", "bed"), ("host", "Host", "h", "h")] {
                try session.addTrack(TrackID(track), name: name, layout: .mono)
                try session.addFile(AudioFile(id: FileID(file), path: "\(file).wav", layout: .mono, length: 1_000_000))
                try session.place(
                    Clip(id: ClipID(clip), file: FileID(file), start: 0, offset: 0, length: 960_000), on: TrackID(track)
                )
            }
            try session.setFollowTrack(true, tracks: ["bed"])
            try session.write(to: url)
        }.value
        return url
    }

    /// C56 window part: a ruler drag and Cut, then Select All and Insert at the playhead, give the
    /// `host` lane back and keep the bed one clip. A range drawn on `bed` alone pastes on `bed`.
    @Test func aCutThenInsertAtTheSamePlaceRestoresTheLanes() async throws {
        let (model, studio) = try await timelineModel(try await packageG(), app: app)
        let before = studio.session
        model.timeline.selection = rulerRange(before)
        model.run(.cut)
        #expect(app.clipboard?.excerpt.lanes.map(\.source) == ["host"])
        #expect(lane(studio, "bed") == [0..<960_000] && lane(studio, "host") == Self.cutLane)
        await until("the playhead is at the cut") { studio.playhead == 240_000 }

        model.timeline.selection = .range(Marks.all(in: studio.session))
        model.run(.insert)
        await until("the run ends") { model.importJob == nil }

        let host = try #require(studio.session.track("host"))
        #expect(host.clips.map(\.range) == [0..<240_000, 240_000..<336_000, 336_000..<960_000])
        #expect(host.clips.map(\.offset) == [0, 240_000, 336_000])
        #expect(studio.session.track("bed")?.clips.map(\.id) == ["bed"] && lane(studio, "bed") == [0..<960_000])

        model.undo()
        model.timeline.selection = .range(Marks(inPoint: 240_000, outPoint: 336_000, tracks: ["bed"]))
        model.run(.insert)
        await until("the run ends") { model.importJob == nil }
        let bed = try #require(studio.session.track("bed"))
        #expect(bed.clips.map(\.range) == [0..<240_000, 240_000..<336_000, 336_000..<1_056_000])
        #expect(bed.clips.map(\.file) == ["b", "h", "b"], "the host audio lands on the bed")
        #expect(lane(studio, "host") == [0..<240_000, 336_000..<960_000], "an empty gap on host")
        await model.close()
    }
}
