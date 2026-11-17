import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

/// A range reference keeps the file frames of the choice: an edit that moves the clip reads the
/// same audio, and an edit that removes part of the range ends the reference.
extension MatchVoiceWindowTests {
    /// Moves c1 to 4 s and chooses 6 s to 30 s on t1 as the reference: file frames 2 s to 26 s.
    func chooseRange(_ model: SessionWindow, _ studio: Studio) throws {
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.move("c1", to: "t1", start: Frames(4 * 48_000))
        }
        model.timeline.selection = .range(
            Marks(inPoint: Frames(6 * 48_000), outPoint: Frames(30 * 48_000), tracks: ["t1"]))
        model.useAsVoiceReference()
    }

    func rippleDelete(_ seconds: Range<Int>, _ studio: Studio) throws {
        try studio.edit(ripple: true) { session throws(SessionError) in
            try session.rippleDelete(
                Frames(seconds.lowerBound * 48_000)..<Frames(seconds.upperBound * 48_000), on: ["t1"],
                naming: ["t1"])
        }
    }

    @Test func aRippleBeforeTheReferenceReadsTheSameAudio() async throws {
        let (model, studio) = try await open(seconds: 30)
        try chooseRange(model, studio)
        await model.matchVoice(tracks: ["t2"])
        let chosen = try #require(studio.session.track("t2")?.match, "\(String(describing: model.voiceMatchReport))")
        try studio.undo()

        try rippleDelete(0..<2, studio)
        #expect(studio.session.clip("c1")?.clip.start == Frames(2 * 48_000))
        await model.matchVoice(tracks: ["t2"])

        #expect(
            studio.session.track("t2")?.match == chosen,
            "the learn reads file frames 2 s to 26 s: \(String(describing: model.voiceMatchReport))")
        await model.close()
    }

    /// A ripple cut and a trim inside the range end the reference; their undo brings it back. A
    /// slip that keeps the frames in the clip keeps it.
    @Test func anEditThatRemovesPartOfTheRangeEndsTheReference() async throws {
        let (model, studio) = try await open(seconds: 30)
        try chooseRange(model, studio)
        #expect(model.canMatchVoice(tracks: ["t2"]))

        try rippleDelete(10..<11, studio)
        #expect(model.activeVoiceReference == nil && !model.canMatchVoice(tracks: ["t2"]), "a cut")
        try studio.undo()
        #expect(model.canMatchVoice(tracks: ["t2"]), "the undo of the cut")

        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.trim("c1", to: Frames(4 * 48_000)..<Frames(20 * 48_000))
        }
        #expect(model.activeVoiceReference == nil, "a trim")
        try studio.undo()

        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.trim("c1", to: Frames(4 * 48_000)..<Frames(31 * 48_000))
            try session.slip(["c1"], by: Frames(2 * 48_000))
        }
        #expect(model.activeVoiceReference != nil, "a slip that keeps the frames")
        await model.close()
    }

    /// Match Voice is off when the only target is the track of the reference clip. Next to another
    /// track it is on, and the match leaves the reference track as it was.
    @Test func theReferenceTrackIsNoTarget() async throws {
        let (model, studio) = try await open()
        model.timeline.selection = ClipSet(["c1"]).map { Selection.clips($0) } ?? .none
        model.useAsVoiceReference()
        #expect(!model.canMatchVoice(tracks: ["t1"]), "the reference track alone")
        #expect(model.canMatchVoice(tracks: ["t1", "t2"]))

        await model.matchVoice(tracks: ["t1", "t2"])

        #expect(studio.session.track("t1")?.match == nil && studio.session.track("t2")?.match != nil)
        if case .voiceMatched(let result, _) = model.voiceMatchReport?.banner {
            #expect(result.tracks == 1, "the banner counts the matched track only")
        } else {
            Issue.record("no result banner: \(String(describing: model.voiceMatchReport))")
        }
        await model.close()
    }
}
