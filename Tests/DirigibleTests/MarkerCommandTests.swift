import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Edit-commands criterion 21: the marker and chapter commands on a real Studio. Tracks t1 and t2
/// each have a clip of file f1 at 0..<2 880 000.
@Suite(.serialized) @MainActor struct MarkerCommandTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func open(audio: Bool = false) async throws -> (SessionWindow, Studio, NSWindow) {
        let (model, studio, window, lanes) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 60, audio: audio))
        #expect(window.makeFirstResponder(lanes.lanes))
        return (model, studio, window)
    }

    func seek(_ studio: Studio, _ frame: Frames) async {
        await studio.perform(.seek(.frame(frame)))
        #expect(studio.playhead == frame)
    }

    /// Adds the markers m1 (48 000), c2 (a chapter at 96 000), and m3 (96 000), one undo entry.
    func threeMarkers(_ studio: Studio) throws {
        try studio.edit { s throws(SessionError) in
            try s.setMarker(Marker(id: "m1", name: "One", position: 48_000, kind: .marker))
            try s.setMarker(Marker(id: "c2", name: "Two", position: 96_000, kind: .chapter))
            try s.setMarker(Marker(id: "m3", name: "Three", position: 96_000, kind: .marker))
        }
    }

    @Test func addMarkerAtThePlayheadIsTheCurrentMarker() async throws {
        let (model, studio, _) = try await open()
        await seek(studio, 24_000)

        model.run(.addMarker)

        let marker = try #require(studio.session.markers.values.first)
        #expect(studio.session.markers.count == 1)
        #expect(marker.name == L10n.markerDefaultName.format(1) && marker.position == 24_000 && marker.kind == .marker)
        #expect(model.timeline.marker == marker.id)
        model.undo()
        #expect(studio.session.markers.isEmpty && !studio.canUndo)
        await model.close()
    }

    /// N counts the markers and the chapters. The test process has no app strings, so the test
    /// reads N from `newMarkerName`. Controls: a count of the markers only gives Marker 1; a count
    /// + 2 gives Chapter 2.
    @Test func addChapterNamesChapterN() async throws {
        let (model, studio, _) = try await open()
        let first = newMarkerName(.chapter, in: studio.session)

        model.run(.addChapter)
        let second = newMarkerName(.marker, in: studio.session)
        model.run(.addMarker)

        #expect(first.key == .chapterDefaultName && first.number == 1)
        #expect(second.key == .markerDefaultName && second.number == 2)
        #expect(
            studio.session.markers.values.map { "\($0.kind) \($0.name)" }.sorted() == [
                "chapter \(L10n.chapterDefaultName.format(1))", "marker \(L10n.markerDefaultName.format(2))",
            ])
        #expect(studio.session.markers[try #require(model.timeline.marker)]?.kind == .marker)
        await model.close()
    }

    /// At 96 000 the marker m3 comes before the chapter c2. With none found, the slot stays.
    @Test func nextAndPreviousSeekAndSetTheCurrentMarker() async throws {
        let (model, studio, _) = try await open()
        try threeMarkers(studio)
        await seek(studio, 60_000)

        model.run(.nextMarker)
        #expect(model.timeline.marker == "m3")
        await until("Next seeks to 96 000") { studio.playhead == 96_000 }
        model.run(.nextMarker)
        #expect(model.timeline.marker == "m3" && studio.playhead == 96_000)

        model.run(.previousMarker)
        #expect(model.timeline.marker == "m1")
        await until("Previous seeks to 48 000") { studio.playhead == 48_000 }
        #expect(!studio.canRedo && studio.session.markers.count == 3)
        await model.close()
    }

    /// Control: a Next that includes the playhead stays on m1.
    @Test func nextFromAMarkerGoesToTheNextOne() async throws {
        let (model, studio, _) = try await open()
        try threeMarkers(studio)
        await seek(studio, 48_000)

        model.run(.nextMarker)

        #expect(model.timeline.marker == "m3")
        await until("Next seeks to 96 000") { studio.playhead == 96_000 }
        await model.close()
    }

    /// Control: a rename of the first marker of the session (c2 by ID) renames another marker.
    @Test func renameActsOnTheCurrentMarker() async throws {
        let (model, studio, _) = try await open()
        try threeMarkers(studio)
        model.timeline.marker = "m3"

        model.run(.renameMarker)
        #expect(model.timeline.renaming == MarkerRename(id: "m3", name: "Three"))
        model.timeline.renaming?.name = "Intro"
        model.commitRename()

        #expect(studio.session.markers.values.map(\.name).sorted() == ["Intro", "One", "Two"])
        #expect(studio.session.markers["m3"]?.name == "Intro" && model.timeline.renaming == nil)
        model.undo()
        #expect(studio.session.markers["m3"]?.name == "Three")
        await model.close()
    }

    @Test func renameWithANewlineIsRefused() async throws {
        let (model, studio, _) = try await open()
        try threeMarkers(studio)
        model.timeline.marker = "m1"
        let before = studio.session

        model.run(.renameMarker)
        model.timeline.renaming?.name = "A\nB"
        model.commitRename()

        #expect(studio.session == before)
        #expect(model.alert == .error(.session(.invalidText("A\nB"))))
        await model.close()
    }

    @Test func moveToPlayhead() async throws {
        let (model, studio, _) = try await open()
        try threeMarkers(studio)
        model.timeline.marker = "m1"
        await seek(studio, 200_000)

        model.run(.moveMarker)

        #expect(studio.session.markers["m1"]?.position == 200_000)
        #expect(studio.session.markers["m3"]?.position == 96_000)
        model.undo()
        #expect(studio.session.markers["m1"]?.position == 48_000)
        await model.close()
    }

    /// After Delete and Undo, m1 is back, but the slot is empty. Control: a Delete that keeps the
    /// slot deletes m1 again.
    @Test func deleteClearsTheSlotAndASecondDeleteDoesNothing() async throws {
        let (model, studio, _) = try await open()
        try threeMarkers(studio)
        model.timeline.marker = "m1"

        model.run(.deleteMarker)
        #expect(studio.session.markers["m1"] == nil && model.timeline.marker == nil)
        model.undo()
        model.run(.deleteMarker)

        #expect(studio.session.markers["m1"] != nil && model.alert == nil)
        await model.close()
    }

    /// Controls: an act on the gone ID shows an alert; a Rename that never acts fails
    /// `renameActsOnTheCurrentMarker`.
    @Test func anUndoneMarkerIsNotActedOn() async throws {
        let (model, studio, _) = try await open()
        await seek(studio, 24_000)
        model.run(.addMarker)
        model.undo()
        let before = studio.session

        for command in [TimelineCommand.renameMarker, .moveMarker, .deleteMarker] { model.run(command) }

        #expect(studio.session == before && model.alert == nil && model.timeline.renaming == nil)
        await model.close()
    }

    /// Controls: an Esc that keeps the slot fails; an Esc that clears only the slot keeps the Marks.
    @Test func escClearsTheCurrentMarker() async throws {
        let (model, studio, window) = try await open()
        try threeMarkers(studio)
        model.timeline.marker = "m1"
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])

        _ = window.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)

        #expect(model.timeline.marker == nil && model.timeline.marks == Marks())
        await model.close()
    }

    /// Criterion 20 during play: the marker goes where the playhead is at the action, and the
    /// play goes on.
    @Test func addMarkerDuringPlayUsesThePlayhead() async throws {
        let (model, studio, _) = try await open(audio: true)
        studio.environment.playerOutput = .offline
        await seek(studio, 0)
        await studio.perform(.playStop)
        _ = await studio.renderOffline(frames: 9_600)
        await until(limit: .seconds(10), "the playhead moves") { studio.playhead > 0 }
        let playhead = studio.playhead

        model.run(.addMarker)

        #expect(studio.session.markers.values.map(\.position) == [playhead])
        _ = await studio.renderOffline(frames: 9_600)
        await until(limit: .seconds(10), "the playhead moves after the add") { studio.playhead > playhead }
        #expect(studio.playback == .playing(Shuttle(direction: .forward, rate: .one)))
        await studio.perform(.playStop)
        await model.close()
    }
}
