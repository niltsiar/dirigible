import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

extension TranscriptSelectionTests {
    /// C51 window part (decision 0073): with the flag on `t1` and `t2`, a pane Cut of "Second part" on
    /// `t1` cuts `t1` as `cutWords` does, keeps the follow track `t2` whole, and copies one lane.
    @Test func aPaneCutOfAWordOnAFollowTrackCutsThatTrack() async throws {
        let (model, studio, window, _, pane) = try await shown(follow: ["t1", "t2"])
        let before = studio.session
        var expected = before
        try expected.cutWords(before.words(in: 288_000..<336_000).map(\.occurrence))
        try #require(expected.track("t1")?.clips.count == 2, "the word cut splits t1")

        pane.setSelectedRange(try range("Second", "part", in: pane))
        app.timeline(.cut, event: key(.keyDown, "x", code: 7, in: window), in: window)

        #expect(studio.session.track("t1")?.clips == expected.track("t1")?.clips)
        #expect(studio.session.track("t2")?.clips == before.track("t2")?.clips, "t2 follows and stays whole")
        #expect(app.clipboard?.excerpt.lanes.map(\.source) == ["t1"])

        window.close()
        await model.close()
    }

    /// C51 window part: the pane Delete of the same word gives the same lanes and no clipboard.
    @Test func aPaneDeleteOfAWordOnAFollowTrackCutsThatTrack() async throws {
        let (model, studio, window, _, pane) = try await shown(follow: ["t1", "t2"])
        let before = studio.session
        var expected = before
        try expected.cutWords(before.words(in: 288_000..<336_000).map(\.occurrence))

        pane.setSelectedRange(try range("Second", "part", in: pane))
        app.timeline(.delete, event: key(.keyDown, "\u{8}", code: 51, in: window), in: window)

        #expect(studio.session.track("t1")?.clips == expected.track("t1")?.clips)
        #expect(studio.session.track("t2")?.clips == before.track("t2")?.clips)
        #expect(app.clipboard == nil)
        window.close()
        await model.close()
    }
}
