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

        #expect(studio.session.tracks.map(\.id) == ["t2"])
        model.undo()
        #expect(studio.session == before && !studio.canUndo)
        await model.close()
    }

    /// Control: a remove that drops the armed entry too loses t1 from the armed set.
    @Test func theDraftDropsAndTheArmedSetStays() async throws {
        let (model, studio, _, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 60))
        model.drafts = ["t1": "Host", "t2": "Guest"]
        model.timeline.marks = Marks(tracks: ["t1"])
        // Both tracks are on channel 1 of duo, so the open arms only t1 (code gate E1).
        let armed = model.armed
        try #require(armed.contains("t1"))

        model.run(.removeTrack)

        #expect(studio.session.tracks.map(\.id) == ["t2"])
        #expect(model.drafts == ["t2": "Guest"])
        #expect(model.armed == armed)
        await model.close()
    }

    /// Control: a remove that drops the armed entry too records nothing on t1 after the undo.
    @Test func undoAfterRemoveTrackRecordsOnTheArmedTrack() async throws {
        let model = await app.open(try await package())
        let studio = try #require(await model.opened() ? model.studio : nil)
        studio.environment = hal.environment
        model.timeline.marks = Marks(tracks: ["t1"])
        model.run(.removeTrack)
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

        #expect(studio.session.tracks.map(\.id) == ["t1"])
        await model.close()
    }
}
