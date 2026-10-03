import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Edit-commands criterion 20: the edit commands during a take and during play, on a real Studio
/// with the counting HAL.
@Suite(.serialized) @MainActor struct EditTakeTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let hal = CountingHAL()

    init() throws { folder = try TemporaryFolder() }

    /// Tracks t1 and t2 on channels 1 and 2 of `duo`, each with a clip of the missing file f1 at
    /// 0..<2 880 000. The write runs off the main actor.
    func package() async throws -> URL {
        let url = folder.url.appending(path: "take.dirigible")
        try await Task.detached {
            var session = Session(sampleRate: 48_000)
            try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 2_880_000))
            for (n, channel) in [(1, 1), (2, 2)] {
                let track = TrackID("t\(n)")
                try session.addTrack(track, name: "T\(n)", layout: .mono)
                try session.setRoute(Route.device(uid: "duo", channels: .mono(channel)), track: track)
                try session.place(
                    Clip(id: ClipID("c\(n)"), file: "f1", start: 0, offset: 0, length: 2_880_000), on: track)
            }
            try session.write(to: url)
        }.value
        return url
    }

    /// Cut, Paste, Delete, Split, Nudge, the marker edits, and Remove Track change nothing and show no alert
    /// while a take records; Rename Marker opens no alert; a refused Cut keeps the clipboard, and a
    /// refused Delete Marker keeps the current marker. Copy runs. The take goes on: after the stop, each track has a take
    /// clip with frames. Controls: an edit with no idle check shows the `.busy` alert; a clipboard
    /// set before the edit changes on the refused Cut.
    @Test func editsDoNothingDuringATake() async throws {
        let model = await app.open(try await package())
        let studio = try #require(await model.opened() ? model.studio : nil)
        studio.environment = hal.environment
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        model.run(.copy)
        let copied = try #require(model.clipboard)
        model.run(.addMarker)
        let marker = try #require(model.timeline.marker)
        model.timeline.marks = Marks(inPoint: 96_000, outPoint: 192_000, tracks: ["t1", "t2"])

        await model.record()
        #expect(studio.transport == .recording(take: 1))
        await hal.feed(seconds: 0.5)
        let (before, undo) = (studio.session, studio.canUndo)
        for command in [TimelineCommand.cut, .paste, .delete, .split] { model.run(command) }
        model.timeline.marks = Marks(inPoint: 0, outPoint: 2_880_000, tracks: ["t1"])
        model.run(.nudgeRight)
        model.run(.fade)
        model.timeline.marks = Marks(inPoint: 96_000, outPoint: 192_000, tracks: ["t1", "t2"])
        for command in [
            TimelineCommand.addMarker, .addChapter, .moveMarker, .renameMarker, .deleteMarker, .removeTrack,
        ] {
            model.run(command)
        }

        #expect(studio.session == before && studio.canUndo == undo && model.alert == nil)
        #expect(model.timeline.renaming == nil, "the rename alert opened during the take")
        #expect(model.clipboard == copied && model.timeline.marker == marker)
        model.run(.copy)
        #expect(model.clipboard?.length == 96_000)
        await hal.feed(seconds: 0.5)
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        for track in studio.session.tracks {
            #expect(track.clips.contains { $0.file != "f1" && $0.length > .zero }, "\(track.id) has no take clip")
        }
        await model.close()
    }

    /// A take that starts while the rename alert is open: OK saves nothing and keeps the typed name
    /// in the alert state; OK after the take saves it (code gate 1 item 1). Controls: an OK that
    /// drops the state during the take fails; an OK that always keeps the state fails
    /// `MarkerCommandTests.renameActsOnTheCurrentMarker`.
    @Test func aRenameOpenAtATakeStartKeepsItsName() async throws {
        let model = await app.open(try await package())
        let studio = try #require(await model.opened() ? model.studio : nil)
        studio.environment = hal.environment
        model.run(.addMarker)
        let marker = try #require(model.timeline.marker)
        model.run(.renameMarker)
        model.timeline.renaming?.name = "Intro"

        await model.record()
        #expect(studio.transport == .recording(take: 1))
        await hal.feed(seconds: 0.5)
        let before = studio.session
        model.commitRename()

        #expect(studio.session == before && model.alert == nil)
        #expect(model.timeline.renaming == MarkerRename(id: marker, name: "Intro"))
        await hal.feed(seconds: 0.5)
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        model.commitRename()
        #expect(studio.session.markers[marker]?.name == "Intro" && model.timeline.renaming == nil)
        await model.close()
    }

    /// Control: an edit that stops the play first leaves the playhead still.
    @Test func anEditDuringPlayKeepsThePlayGoing() async throws {
        let model = await app.open(try await timelinePackage(in: folder.url, tracks: 2, seconds: 10, audio: true))
        let studio = try #require(await model.opened() ? model.studio : nil)
        studio.environment.playerOutput = .offline
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        model.timeline.marks = Marks(inPoint: 0, outPoint: 24_000, tracks: ["t1"])

        model.run(.delete)

        #expect(studio.session.track("t1")?.clips.first?.start == 24_000)
        // An offline Player moves the playhead only by the frames that the test renders.
        let playhead = studio.playhead
        _ = await studio.renderOffline(frames: 9_600)
        await until(limit: .seconds(10), "the playhead moves after the edit") { studio.playhead > playhead }
        #expect(studio.playback == .playing(Shuttle(direction: .forward, rate: .one)))
        await studio.perform(.playStop)
        await model.close()
    }

    /// A mouse event at the document point `point` of the lanes of `view`, 40 pt right of and
    /// 10 pt under the top left of the box of c1 plus `dx` (the move zone).
    func onC1(_ type: NSEvent.EventType, dx: Double, in view: TimelineScrollView) throws -> NSEvent {
        let box = try #require(view.lanes.clipFrame("c1"))
        return try mouse(type, NSPoint(x: box.minX + 40 + dx, y: box.minY + 10), in: view)
    }

    /// Mouse-edits criterion 9: a take that starts during a move drag drops the commit, with no
    /// alert. The take goes on: after the stop, each track has a take clip. The take starts at
    /// 3,000,000, after c1, so it does not overwrite c1.
    @Test func aTakeDuringADragDropsTheCommit() async throws {
        let (model, studio, _, view) = try await openLanes(app, try await package())
        studio.environment = hal.environment
        await studio.perform(.seek(.frame(3_000_000)))
        view.lanes.mouseDown(with: try onC1(.leftMouseDown, dx: 0, in: view))
        view.lanes.mouseDragged(with: try onC1(.leftMouseDragged, dx: 20, in: view))
        #expect(view.lanes.inputs?.session.clip("c1")?.clip.start != 0, "the drag shows a preview")

        await model.record()
        #expect(studio.transport == .recording(take: 1))
        await hal.feed(seconds: 0.5)
        view.lanes.mouseDragged(with: try onC1(.leftMouseDragged, dx: 40, in: view))
        view.lanes.mouseUp(with: try onC1(.leftMouseUp, dx: 40, in: view))

        #expect(studio.session.clip("c1")?.clip.start == 0 && model.alert == nil)
        await hal.feed(seconds: 0.5)
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        #expect(studio.session.clip("c1")?.clip.start == 0)
        for track in studio.session.tracks {
            #expect(track.clips.contains { $0.file != "f1" && $0.length > .zero }, "\(track.id) has no take clip")
        }
        await model.close()
    }

    /// Mouse-edits criterion 9: a move during play commits, and the play goes on (Q12). Control
    /// of `anEditDuringPlayKeepsThePlayGoing`: an edit that stops the play leaves the playhead
    /// still.
    @Test func aMoveDuringPlayKeepsThePlay() async throws {
        let (model, studio, _, view) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 10, audio: true))
        studio.environment.playerOutput = .offline
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)

        view.lanes.mouseDown(with: try onC1(.leftMouseDown, dx: 0, in: view))
        view.lanes.mouseDragged(with: try onC1(.leftMouseDragged, dx: 20, in: view))
        view.lanes.mouseUp(with: try onC1(.leftMouseUp, dx: 20, in: view))

        let moved = try #require(studio.session.clip("c1")?.clip)
        #expect(moved.start > .zero && moved.length == 480_000, "the move commits")
        let playhead = studio.playhead
        _ = await studio.renderOffline(frames: 9_600)
        await until(limit: .seconds(10), "the playhead moves after the move") { studio.playhead > playhead }
        #expect(studio.playback == .playing(Shuttle(direction: .forward, rate: .one)))
        await studio.perform(.playStop)
        await model.close()
    }
}
