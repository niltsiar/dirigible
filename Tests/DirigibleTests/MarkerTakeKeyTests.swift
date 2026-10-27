import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// F107 C9: Command-Return through `AppDelegate.timeline(_:event:in:)` during a take, on a real
/// Studio with the counting HAL. Tracks t1 and t2 sit on channels 1 and 2 of the device `duo`.
@Suite(.serialized) @MainActor struct MarkerTakeKeyTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let hal = CountingHAL()

    init() throws { folder = try TemporaryFolder() }

    func open(_ name: String, tracks: Int) async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let url = folder.url.appending(path: "\(name).dirigible")
        try await Task.detached {
            var session = Session(sampleRate: 48_000)
            for n in 1...tracks {
                let track = TrackID("t\(n)")
                try session.addTrack(track, name: "T\(n)", layout: .mono)
                try session.setRoute(Route.device(uid: "duo", channels: .mono(n)), track: track)
            }
            try session.write(to: url)
        }.value
        let opened = try await openLanes(app, url)
        opened.1.environment = hal.environment
        return opened
    }

    /// A window with a take that records on `tracks` tracks.
    func recording(tracks: Int = 1) async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let opened = try await open("take", tracks: tracks)
        await opened.0.record()
        #expect(opened.1.transport == .recording(take: 1))
        await hal.feed(seconds: 0.2)
        return opened
    }

    func finish(_ model: SessionWindow, _ studio: Studio) async {
        await hal.feed(seconds: 0.2)
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        await model.close()
    }

    /// C9a: the lanes have the focus. Control: the marker is at the record head, not at the playhead.
    @Test func theKeyMarksTheTakeFromTheLanes() async throws {
        let (model, studio, window, view) = try await recording()
        #expect(window.makeFirstResponder(view.lanes))
        let before = try #require(studio.liveHead())

        app.timeline(.addMarker, event: returnKey(in: window), in: window)

        let marker = try #require(studio.session.markers.values.first)
        #expect(studio.session.markers.count == 1 && marker.kind == .marker)
        #expect(marker.position >= before && before > .zero, "\(marker.position) \(before)")
        await finish(model, studio)
    }

    /// C9b: the focus is on the track headers, not in a text field.
    @Test func theKeyMarksTheTakeFromTheTrackHeaders() async throws {
        let (model, studio, window, view) = try await recording()
        window.makeFirstResponder(view.headers)
        #expect(!(window.firstResponder is NSText))

        app.timeline(.addMarker, event: returnKey(in: window), in: window)

        #expect(studio.session.markers.count == 1)
        await finish(model, studio)
    }

    /// C9c: no first responder view.
    @Test func theKeyMarksTheTakeWithNoFirstResponder() async throws {
        let (model, studio, window, _) = try await recording()
        #expect(window.makeFirstResponder(nil))

        app.timeline(.addMarker, event: returnKey(in: window), in: window)

        #expect(studio.session.markers.count == 1)
        await finish(model, studio)
    }

    /// C9f: a take on two tracks gets one marker. Shift-Command-Return adds a chapter.
    @Test func aTakeOnTwoTracksGetsOneMarkerAndOneChapter() async throws {
        let (model, studio, window, view) = try await recording(tracks: 2)
        #expect(window.makeFirstResponder(view.lanes))

        app.timeline(.addMarker, event: returnKey(in: window), in: window)
        app.timeline(.addChapter, event: returnKey(in: window, shift: true), in: window)

        #expect(
            studio.session.markers.count == 2 && Set(studio.session.markers.values.map(\.kind)) == [.chapter, .marker])
        await finish(model, studio)
    }

    /// C9d: no session window is key (the Settings window or the start window), so the key adds no
    /// marker. Control of C9e.
    @Test func noKeySessionWindowTakesNoMarker() async throws {
        let (model, studio, window, _) = try await recording()
        app.key = nil

        app.timeline(.addMarker, event: returnKey(in: window), in: window)

        #expect(studio.session.markers.isEmpty)
        await finish(model, studio)
    }

    /// C9e: an idle second session window is key. Its session gets the marker at its own playhead,
    /// and the session that records gets none.
    @Test func aKeyIdleWindowMarksItsOwnPlayhead() async throws {
        let (recorder, recording, _, _) = try await recording()
        let (idle, idleStudio, window, _) = try await open("idle", tracks: 1)
        await idleStudio.perform(.seek(.frame(24_000)))

        app.timeline(.addMarker, event: returnKey(in: window), in: window)

        #expect(idleStudio.session.markers.values.map(\.position) == [24_000])
        #expect(recording.session.markers.isEmpty)
        await idle.close()
        await finish(recorder, recording)
    }

    /// C9g: a held key adds one marker, during a take and when idle. Control: a second key-down
    /// that is no repeat adds a second marker.
    @Test func aHeldKeyAddsOneMarker() async throws {
        let (idle, idleStudio, idleWindow, _) = try await open("idle", tracks: 1)
        app.timeline(.addMarker, event: returnKey(in: idleWindow), in: idleWindow)
        app.timeline(.addMarker, event: returnKey(in: idleWindow, repeats: true), in: idleWindow)
        #expect(idleStudio.session.markers.count == 1, "idle: a repeat added a marker")
        app.timeline(.addMarker, event: returnKey(in: idleWindow), in: idleWindow)
        #expect(idleStudio.session.markers.count == 2, "idle: a second press adds a marker")
        await idle.close()

        let (model, studio, window, _) = try await recording()
        app.timeline(.addMarker, event: returnKey(in: window), in: window)
        app.timeline(.addMarker, event: returnKey(in: window, repeats: true), in: window)
        #expect(studio.session.markers.count == 1, "a take: a repeat added a marker")
        app.timeline(.addChapter, event: returnKey(in: window, shift: true, repeats: true), in: window)
        #expect(studio.session.markers.count == 1, "a take: a repeat added a chapter")
        app.timeline(.addMarker, event: returnKey(in: window), in: window)
        #expect(studio.session.markers.count == 2, "a take: a second press adds a marker")
        await finish(model, studio)
    }
}
