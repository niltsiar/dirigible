import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The commands that ripple the timeline (decision 0037).
let rippleCommands: [TimelineCommand] = [
    .cut, .deleteCloseGap, .cutSelectedTracks, .deleteCloseGapSelectedTracks, .insert,
]

/// C20: no ripple under a split take; a wholly unplaced take allows one.
extension UnplacedBannerTests {
    /// Control: a ripple that runs with a split take changes the session.
    @Test func aSplitTakeRefusesEveryRipple() async throws {
        let (model, studio) = try await open()
        _ = try await unplacedTake(model, studio)
        await model.place(Self.first, atPlayhead: false)
        try #require(studio.unplacedSegments == [Self.second])
        model.timeline.marks = Marks(inPoint: 0, outPoint: 4_800, tracks: ["t1"])
        model.run(.copy)
        let before = studio.session
        for command in rippleCommands { model.run(command) }
        #expect(studio.session == before, "RIPPLE-W1 a ripple ran with a split take")
        #expect(model.alert == nil)
        await model.close()
    }

    /// Control: the guard of any unplaced segment refuses this ripple.
    @Test func anUndoneTakeAllowsARipple() async throws {
        let (model, studio) = try await open()
        _ = try await unplacedTake(model, studio)
        _ = try studio.edit { session throws(SessionError) in
            try session.setMarker(Marker(id: "m", name: "M", position: 10_000, kind: .marker))
        }
        let before = studio.session
        model.timeline.marks = Marks(inPoint: 0, outPoint: 4_800, tracks: ["t1"])

        model.run(.deleteCloseGap)

        #expect(studio.session.markers["m"]?.position == 5_200, "RIPPLE-W2 the ripple ran")
        model.undo()
        #expect(studio.session == before, "one undo entry")
        await model.close()
    }
}

/// C20: no ripple under a pending take.
extension EditTakeTests {
    /// Control: a ripple that runs with a pending take changes the session.
    @Test func aPendingTakeRefusesEveryRipple() async throws {
        let model = await app.open(try await package())
        let studio = try #require(await model.opened() ? model.studio : nil)
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        model.run(.copy)
        try await pendingTake(model, studio)
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1", "t2"])
        let before = studio.session
        for command in rippleCommands { model.run(command) }
        #expect(studio.session == before, "RIPPLE-W3 a ripple ran with a pending take")
        #expect(model.alert == nil)
        await model.close()
    }
}
