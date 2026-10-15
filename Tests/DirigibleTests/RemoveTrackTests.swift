import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Edit-commands criterion 22: Remove Track on a real Studio with the counting HAL. The package of
/// `EditTakeTests` has t1 and t2 on channels 1 and 2 of `duo`; both arm at the open.
extension EditTakeTests {
    /// Records 0.5 s on the armed tracks and stops with `Clips/` at mode 0500, so the finalize
    /// throws and the take stays pending. `Clips/` is writable again when this returns.
    func pendingTake(_ model: SessionWindow, _ studio: Studio) async throws {
        studio.environment = hal.environment
        let clips = model.url.appending(path: clipsFolderName)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        await model.record()
        await hal.feed(seconds: 0.5)
        chmod(clips.path, 0o500)
        defer { chmod(clips.path, 0o755) }
        await model.stop()
        await until("the finalize fails") { studio.transport == .idle }
        try #require(studio.pendingTake != nil)
    }

    /// Only t1 is armed in the take. Controls: a remove of the unarmed tracks only removes t2; a
    /// remove of nothing with no alert fails the alert check.
    @Test func aPendingTakeKeepsItsArmedTrack() async throws {
        let model = await app.open(try await package())
        let studio = try #require(await model.opened() ? model.studio : nil)
        try await fixFreeSpace(model)
        model.armed.remove("t2")
        try await pendingTake(model, studio)
        let before = studio.session
        model.timeline.marks = Marks(tracks: ["t1", "t2"])

        model.run(.removeTrack)

        #expect(studio.session == before)
        #expect(model.alert == .error(.session(.trackInRecording("t1"))))
        await model.close()
    }

    @Test func removeTheSelectedTracksInOneEntry() async throws {
        let (model, studio, _, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 3, seconds: 60))
        let before = studio.session
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t3", "t1"])

        model.run(.removeTrack)
        model.confirmRemoveTracks(["t1", "t3"])

        #expect(studio.session.tracks.map(\.id) == ["t2"])
        model.undo()
        #expect(studio.session == before && !studio.canUndo)
        await model.close()
    }

    /// Control: a remove that drops the armed entry too loses t1 from the armed set.
    @Test func theDraftDropsAndTheArmedSetStays() async throws {
        let (model, studio, _, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 60))
        // Both tracks are on channel 1 of mic, so the open arms only t1 (code gate E1). Channel 2
        // arms t2 too.
        model.setRoute(.mono(2), device: InputDevice.placeholder(uid: "mic", channels: 2), track: "t2")
        model.drafts = ["t1": "Host", "t2": "Guest"]
        model.timeline.marks = Marks(tracks: ["t1"])

        model.run(.removeTrack)
        model.confirmRemoveTracks(["t1"])

        #expect(studio.session.tracks.map(\.id) == ["t2"])
        #expect(model.drafts == ["t2": "Guest"])
        #expect(model.armed == ["t1", "t2"])
        await model.close()
    }

    /// Control: a remove that drops the armed entry too records nothing on t1 after the undo.
    @Test func undoAfterRemoveTrackRecordsOnTheArmedTrack() async throws {
        let model = await app.open(try await package())
        let studio = try #require(await model.opened() ? model.studio : nil)
        try await fixFreeSpace(model)
        studio.environment = hal.environment
        model.timeline.marks = Marks(tracks: ["t1"])
        model.run(.removeTrack)
        model.confirmRemoveTracks(["t1"])
        model.undo()

        await model.record()
        #expect(studio.transport == .recording(take: 1))
        await hal.feed(seconds: 0.5)
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }

        #expect(studio.session.track("t1")?.clips.contains { $0.file != "f1" && $0.length > .zero } == true)
        await model.close()
    }

    /// The header menu removes its own track, not the selected one.
    @Test func theHeaderMenuRemovesItsTrack() async throws {
        let (model, studio, _, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 60))
        model.timeline.marks = Marks(tracks: ["t1"])

        model.removeTracks(["t2"])
        #expect(model.alert == .confirmRemoveTracks(["t2"]), "the header menu asks too")
        model.confirmRemoveTracks(["t2"])

        #expect(studio.session.tracks.map(\.id) == ["t1"])
        await model.close()
    }

    /// C17: the menu of a selected row removes the selected tracks. The menu of another row first
    /// selects that row alone, and then removes only its track; a selected row keeps the selection.
    @Test func theHeaderMenuOfASelectedRowRemovesTheSelection() async throws {
        let (model, studio, _, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 4, seconds: 60))
        model.timeline.marks = Marks(tracks: ["t1", "t2"])

        model.showHeaderMenu("t2")
        #expect(model.timeline.marks == Marks(tracks: ["t1", "t2"]), "a selected row keeps the selection")
        model.removeFromHeader("t2")
        #expect(model.alert == .confirmRemoveTracks(["t1", "t2"]))
        model.confirmRemoveTracks(["t1", "t2"])
        #expect(studio.session.tracks.map(\.id) == ["t3", "t4"])

        model.showHeaderMenu("t4")
        #expect(model.timeline.marks == Marks(tracks: ["t4"]), "the menu selects its row first")
        model.timeline.marks = Marks(tracks: ["t3"])
        model.removeFromHeader("t4")
        #expect(model.alert == .confirmRemoveTracks(["t4"]), "a row that is not selected removes its track")
        await model.close()
    }

    /// C1: Remove Track of tracks with clips asks first and changes nothing.
    @Test func aTrackWithClipsAsksFirst() async throws {
        let (model, studio, _, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 3, seconds: 60))
        let before = studio.session
        model.timeline.marks = Marks(tracks: ["t3", "t1"])

        model.run(.removeTrack)

        #expect(model.alert == .confirmRemoveTracks(["t1", "t3"]))
        #expect(studio.session == before && !studio.canUndo)
        await model.close()
    }

    /// C2b: the Remove button passes the IDs of the alert, so the confirm works after the alert
    /// binding set the alert to nil.
    @Test func theConfirmWorksAfterTheAlertCloses() async throws {
        let (model, studio, _, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 3, seconds: 60))
        model.timeline.marks = Marks(tracks: ["t1", "t3"])
        model.run(.removeTrack)
        try #require(model.alert == .confirmRemoveTracks(["t1", "t3"]))

        model.alert = nil
        model.confirmRemoveTracks(["t1", "t3"])

        #expect(studio.session.tracks.map(\.id) == ["t2"])
        await model.close()
    }

    /// C3: Cancel closes the alert and changes nothing.
    @Test func aCancelKeepsTheTracks() async throws {
        let (model, studio, _, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 60))
        let before = studio.session
        model.timeline.marks = Marks(tracks: ["t1"])
        model.run(.removeTrack)
        try #require(model.alert == .confirmRemoveTracks(["t1"]))

        model.alert = nil

        #expect(studio.session == before && !studio.canUndo)
        #expect(model.timeline.marks == Marks(tracks: ["t1"]), "the selection stays")
        await model.close()
    }

    /// C4 and C5: tracks with no clip go with no question; one track with clips asks.
    @Test func emptyTracksGoWithNoQuestion() async throws {
        let (model, studio, _, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 1, seconds: 60))
        model.run(.addTrack)
        model.run(.addTrack)
        let empty = studio.session.tracks.dropFirst().map(\.id)
        try #require(empty.count == 2)

        model.removeTracks([empty[0], "t1"])
        #expect(model.alert == .confirmRemoveTracks([empty[0], "t1"]), "one track with clips asks")
        model.alert = nil

        model.removeTracks(empty)
        #expect(model.alert == nil, "no question")
        #expect(studio.session.tracks.map(\.id) == ["t1"])
        await model.close()
    }

    /// C8b: Return gives Remove, which has no destructive style; Esc gives Cancel.
    @Test func theQuestionButtons() {
        #expect(removeQuestionButtons.map(\.title) == [.alertTrackRemoveConfirm, .alertCancel])
        #expect(removeQuestionButtons.map(\.role) == [nil, .cancel])
    }
}
