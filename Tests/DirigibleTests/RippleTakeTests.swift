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
        var beeps = 0
        model.beep = { beeps += 1 }
        for command in rippleCommands { model.run(command) }
        #expect(studio.session == before, "RIPPLE-W1 a ripple ran with a split take")
        #expect(beeps == rippleCommands.count, "each refused ripple beeps")
        #expect(model.alert == nil)
        await model.close()
    }

    /// Code gate 1 item 2: the unplaced segment of a split take whose CAF is not audio can never
    /// place, so after a reopen it does not block. Control: the block of every unplaced segment.
    @Test func aSplitTakeWithACAFThatIsNotAudioAllowsARipple() async throws {
        let url = try await splitTake()
        try Data("not a CAF".utf8).write(to: url.appending(path: "\(captureFolderName)/\(Self.second.stem).caf"))
        let (reopened, again) = try await timelineModel(url, app: app)
        _ = try again.edit { session throws(SessionError) in
            try session.setMarker(Marker(id: "m", name: "M", position: 10_000, kind: .marker))
        }
        reopened.timeline.marks = Marks(inPoint: 0, outPoint: 4_800, tracks: ["t1"])

        reopened.run(.deleteCloseGap)

        #expect(again.session.markers["m"]?.position == 5_200, "RIPPLE-W4 a CAF that is not audio blocks")
        await reopened.close()
    }

    /// Code gate 2 item 1: a CAF that the user cannot read now (mode 000) can place later, so after
    /// a reopen it still blocks, with a beep. Control: a rule that a CAF that does not open never
    /// blocks.
    @Test func aSplitTakeWithAnUnreadableCAFStaysBlocked() async throws {
        let url = try await splitTake()
        let caf = url.appending(path: "\(captureFolderName)/\(Self.second.stem).caf")
        chmod(caf.path, 0)
        defer { chmod(caf.path, 0o644) }
        let (reopened, again) = try await timelineModel(url, app: app)
        var beeps = 0
        reopened.beep = { beeps += 1 }
        reopened.timeline.marks = Marks(inPoint: 0, outPoint: 4_800, tracks: ["t1"])
        let before = again.session

        reopened.run(.deleteCloseGap)

        #expect(again.session == before && beeps == 1, "RIPPLE-W5 an unreadable CAF does not block")
        await reopened.close()
    }

    /// A split take in a closed package: take1-1-1 placed, take1-2-1 not. The studio goes at the
    /// return, so its package lock goes too.
    func splitTake() async throws -> URL {
        let (model, studio) = try await open()
        _ = try await unplacedTake(model, studio)
        await model.place(Self.first, atPlayhead: false)
        try #require(studio.unplacedSegments == [Self.second])
        await model.close()
        return model.url
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
