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

    /// A render in place keeps the clip ID and gives the clip a new file: the span names the old file,
    /// so the reference ends.
    @Test func aRenderInPlaceEndsTheReference() async throws {
        let (model, studio) = try await open(seconds: 30)
        try chooseRange(model, studio)
        #expect(model.canMatchVoice(tracks: ["t2"]))

        try studio.edit(ripple: false) { session throws(SessionError) in
            let runs = try session.clipRuns(of: ["c1"]).map {
                RenderedRun(run: $0, stem: "\($0.file) NR", treatment: Treatment(.noise(.standard)), addedGain: .zero)
            }
            _ = try session.repoint(runs)
        }

        #expect(studio.session.clip("c1")?.clip.file != "f1", "the clip reads the rendered file")
        #expect(model.activeVoiceReference == nil && !model.canMatchVoice(tracks: ["t2"]), "a new file")
        await model.close()
    }

    /// A trim of the clip start past the start of the span removes frames of the span and ends the
    /// reference. A trim before it keeps the file frames of the span.
    @Test func aTrimOfTheClipStartPastTheSpanEndsTheReference() async throws {
        let (model, studio) = try await open(seconds: 30)
        try chooseRange(model, studio)
        let frames = try #require(model.voiceReference?.span?.frames)
        #expect(frames == Frames(2 * 48_000)..<Frames(26 * 48_000))

        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.trim("c1", to: Frames(5 * 48_000)..<Frames(34 * 48_000))
        }
        let session = studio.session
        #expect(model.activeVoiceReference?.span?.frames == frames, "a trim before the span")
        #expect(model.activeVoiceReference?.range(in: session) == Frames(6 * 48_000)..<Frames(30 * 48_000))
        try studio.undo()

        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.trim("c1", to: Frames(8 * 48_000)..<Frames(34 * 48_000))
        }
        #expect(model.activeVoiceReference == nil && !model.canMatchVoice(tracks: ["t2"]), "a trim past the span start")
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
        await model.close()
    }

    /// C9 (h): a Match Voice that matched tracks shows no banner, because the mark of each track shows
    /// the match. VoiceOver hears the result once, and it counts the matched track only.
    @Test func matchVoiceShowsNoBannerAndIsAnnounced() async throws {
        let (model, studio) = try await open()
        var heard: [String] = []
        model.chrome?.announce = { text, _ in heard.append(text) }
        model.timeline.selection = ClipSet(["c1"]).map { Selection.clips($0) } ?? .none
        model.useAsVoiceReference()

        await model.matchVoice(tracks: ["t1", "t2"])

        let match = try #require(studio.session.track("t2")?.match)
        let extremes = match.extremes(at: match.amount)
        let text = L10n.matchResult(VoiceMatchResult(tracks: 1, boost: extremes.boost, cut: extremes.cut))
        #expect(heard.count(where: { $0 == text }) == 1, "VoiceOver hears the result once: \(heard)")
        let banners = ChromeState.reportBanners(model, studio)
        #expect(!banners.contains { $0.text == text }, "a match that worked has no banner: \(banners)")
        await model.close()
    }

    /// The result text has one form for 1 track and one for more (decision 0010, Voice).
    @Test func theResultTextHasAFormForOneTrack() throws {
        let english = try stringsTable("en")
        let text = { (key: L10n) in english[key.rawValue] ?? key.rawValue }
        let one = L10n.matchResult(VoiceMatchResult(tracks: 1, boost: 4, cut: -2), text: text)
        let many = L10n.matchResult(VoiceMatchResult(tracks: 3, boost: 4, cut: -2), text: text)
        #expect(one.hasPrefix("Matched 1 track, "), "\(one)")
        #expect(many.hasPrefix("Matched 3 tracks, "), "\(many)")
    }
}
