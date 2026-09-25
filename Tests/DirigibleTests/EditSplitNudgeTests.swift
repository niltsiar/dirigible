import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Edit-commands criteria 17 and 18: Split and Nudge on a real Studio. Tracks t1 to t3 each have
/// a clip of file f1 at 0..<2 880 000.
extension EditCommandWindowTests {
    /// Splits t1 at 48 000 and 96 000 and clears 0..<200 on t1 (one undo entry, not counted by the
    /// tests below): c1 200..<48 000, c1@48000 48 000..<96 000, c1@96000 96 000..<2 880 000.
    func threeClipsOnT1(_ studio: Studio) throws {
        try studio.edit { s throws(SessionError) in
            try s.splitClips(at: [48_000, 96_000], on: ["t1"])
            try s.clear(0..<200, on: "t1")
        }
    }

    /// Control: a split on the first selected track only leaves t2; a split on every track cuts t3.
    @Test func splitWithARangeSplitsAtInAndOutOnTheSelectedTracks() async throws {
        let (model, studio, _, _) = try await open()
        let before = studio.session
        await studio.perform(.seek(.frame(240_000)))
        model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t2", "t1"])

        model.run(.split)

        for n in 1...2 {
            #expect(
                Array(studio.session.track(TrackID("t\(n)"))!.clips) == [
                    clip(ClipID("c\(n)"), 0..<48_000), clip(ClipID("c\(n)@48000"), 48_000..<96_000),
                    clip(ClipID("c\(n)@96000"), 96_000..<2_880_000),
                ])
        }
        #expect(studio.session.track("t3") == before.track("t3"))
        await model.close()
    }

    /// Control: a split at in and out with no range splits nothing.
    @Test func splitWithNoRangeSplitsAtThePlayheadOnTheSelectedTracks() async throws {
        let (model, studio, _, _) = try await open()
        let before = studio.session
        await studio.perform(.seek(.frame(240_000)))
        model.timeline.marks = Marks(inPoint: 48_000, tracks: ["t2"])

        model.run(.split)

        #expect(Array(studio.session.track("t2")!.clips).map(\.id) == ["c2", "c2@240000"])
        #expect(studio.session.track("t1") == before.track("t1") && studio.session.track("t3") == before.track("t3"))
        await model.close()
    }

    @Test func splitWithNoTrackSplitsEveryTrack() async throws {
        let (model, studio, _, _) = try await open()
        await studio.perform(.seek(.frame(240_000)))
        model.timeline.marks = Marks()

        model.run(.split)

        #expect(
            studio.session.tracks.map { $0.clips.map(\.id.rawValue) } == (1...3).map { ["c\($0)", "c\($0)@240000"] })
        await model.close()
    }

    /// One entry for all tracks; a split in a gap or at an edge makes none.
    @Test func splitIsOneUndoEntry() async throws {
        let (model, studio, _, _) = try await open()
        let before = studio.session
        model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1", "t2", "t3"])

        model.run(.split)
        model.undo()

        #expect(studio.session == before && !studio.canUndo)
        model.timeline.marks = Marks(inPoint: 0, outPoint: 2_880_000, tracks: ["t1"])
        model.run(.split)
        #expect(studio.session == before && !studio.canUndo)
        await model.close()
    }

    /// The clip fully inside moves by 10 ms (480 frames), and it cuts the head of its neighbor;
    /// the partly selected c1 and the unselected t2 stay. The Marks move with the clip.
    @Test func nudgeRightMovesTheClipsInsideAndTheMarks() async throws {
        let (model, studio, _, _) = try await open()
        try threeClipsOnT1(studio)
        let before = studio.session
        model.timeline.marks = Marks(inPoint: 40_000, outPoint: 96_000, tracks: ["t1"])

        model.run(.nudgeRight)

        #expect(
            Array(studio.session.track("t1")!.clips) == [
                clip("c1", 200..<48_000),
                Clip(id: "c1@48000", file: "f1", start: 48_480, offset: 48_000, length: 48_000),
                clip("c1@96000", 96_480..<2_880_000),
            ])
        #expect(studio.session.track("t2") == before.track("t2"))
        #expect(model.timeline.marks == Marks(inPoint: 40_480, outPoint: 96_480, tracks: ["t1"]))
        model.undo()
        #expect(studio.session == before)
        await model.close()
    }

    /// Controls: a nudge of the clips that overlap the range, or that start in it, moves c1@96000.
    @Test func aClipPartlyInTheRangeStays() async throws {
        let (model, studio, _, _) = try await open()
        try threeClipsOnT1(studio)
        let before = studio.session
        let marks = Marks(inPoint: 50_000, outPoint: 100_000, tracks: ["t1"])
        model.timeline.marks = marks

        for command in [TimelineCommand.nudgeRight, .nudgeLeft] {
            model.run(command)
            #expect(studio.session == before && model.timeline.marks == marks && model.alert == nil, "\(command)")
        }
        await model.close()
    }

    /// The first clip is 200 frames from 0, so the move is 200 frames, not 480. Controls: no clamp
    /// shows the frame-range alert; a clamp to no move leaves the clips.
    @Test func nudgeLeftStopsAtZero() async throws {
        let (model, studio, _, _) = try await open()
        try threeClipsOnT1(studio)
        model.timeline.marks = Marks(inPoint: 0, outPoint: 96_000, tracks: ["t1"])

        model.run(.nudgeLeft)

        #expect(
            Array(studio.session.track("t1")!.clips).map(\.range) == [0..<47_800, 47_800..<95_800, 96_000..<2_880_000])
        #expect(model.timeline.marks == Marks(inPoint: 0, outPoint: 95_800, tracks: ["t1"]))
        #expect(model.alert == nil)
        model.run(.nudgeLeft)
        #expect(Array(studio.session.track("t1")!.clips).first?.start == 0)
        await model.close()
    }

    /// Control: Marks that stay after the first press leave the moved clip outside the range, so
    /// the second press moves nothing.
    @Test func twoPressesMoveTwice() async throws {
        let (model, studio, _, _) = try await open()
        try threeClipsOnT1(studio)
        model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"])

        model.run(.nudgeRight)
        model.run(.nudgeRight)

        #expect(studio.session.clip("c1@48000")?.clip.range == 48_960..<96_960)
        #expect(model.timeline.marks == Marks(inPoint: 48_960, outPoint: 96_960, tracks: ["t1"]))
        model.undo()
        #expect(studio.session.clip("c1@48000")?.clip.range == 48_480..<96_480)
        await model.close()
    }
}
