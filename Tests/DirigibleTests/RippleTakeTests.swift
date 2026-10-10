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

    /// Plan gate 1: an Insert from another package beeps before the paste commits the typed names.
    @Test func aCrossPackageInsertUnderASplitTakeBeeps() async throws {
        let source = folder.url.appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let (other, _) = try await timelineModel(
            try await timelinePackage(in: source, tracks: 1, seconds: 1, audio: true), app: app)
        other.timeline.marks = Marks(inPoint: 0, outPoint: 4_800, tracks: ["t1"])
        other.run(.copy)
        await other.close()
        try #require(app.clipboard != nil)
        let (model, studio) = try await open()
        _ = try await unplacedTake(model, studio)
        await model.place(Self.first, atPlayhead: false)
        try #require(studio.unplacedSegments == [Self.second])
        model.timeline.marks = Marks(inPoint: 0, outPoint: 4_800, tracks: ["t1"])
        model.drafts["t1"] = "Guest"
        let before = studio.session
        var beeps = 0
        model.beep = { beeps += 1 }

        model.run(.insert)

        #expect(
            beeps == 1 && model.alert == nil && model.importJob == nil && studio.session == before
                && model.drafts["t1"] == "Guest",
            "RIPPLE-W8 a cross-package Insert under a split take beeps and changes nothing")
        await model.close()
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
        var beeps = 0
        model.beep = { beeps += 1 }
        for command in rippleCommands { model.run(command) }
        #expect(studio.session == before, "RIPPLE-W3 a ripple ran with a pending take")
        #expect(beeps == rippleCommands.count, "RIPPLE-W3b each refused ripple beeps")
        #expect(model.alert == nil)
        model.run(.paste)
        #expect(studio.session != before, "RIPPLE-W3c a paste under a pending take pastes")
        await model.close()
    }

    /// Plan gate 1 item 3: Insert with no clipboard under a pending take beeps, as a ripple.
    @Test func anInsertWithNoClipboardUnderAPendingTakeBeeps() async throws {
        let model = await app.open(try await package())
        let studio = try #require(await model.opened() ? model.studio : nil)
        try await pendingTake(model, studio)
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        let before = studio.session
        var beeps = 0
        model.beep = { beeps += 1 }

        model.run(.insert)

        #expect(
            beeps == 1 && studio.session == before && model.alert == nil,
            "RIPPLE-W7 Insert with no clipboard under a pending take beeps")
        await model.close()
    }

    /// Clip-set-clipboard C7b (U18): a failed finalize places no clip of the take, so no set clip
    /// can belong to the pending take, and a set Cut acts. Control: a finalize that places the
    /// clips before it throws fails the first check.
    @Test func aPendingTakeHasNoClipSoASetCutActs() async throws {
        let model = await app.open(try await package())
        let studio = try #require(await model.opened() ? model.studio : nil)
        let clips = studio.session.tracks.map { Array($0.clips) }
        try await pendingTake(model, studio)
        #expect(studio.session.tracks.map { Array($0.clips) } == clips, "the pending take has no clip")
        model.timeline.selection = .clips(try #require(ClipSet(["c1", "c2"])))
        var beeps = 0
        model.beep = { beeps += 1 }

        model.run(.cut)

        #expect(studio.session.tracks.allSatisfy { $0.clips.isEmpty } && beeps == 0)
        #expect(model.clipboard?.kind == .clips && studio.pendingTake != nil)
        model.undo()
        #expect(studio.session.tracks.map { Array($0.clips) } == clips, "one undo entry")
        await model.close()
    }
}
