import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Record monitor run 1b: the Monitor box of a header row, the second box after the arm box. Its
/// state is the state of Track > Monitor Track for its track (decision 0044). Real windows, real
/// packages, and the counting HAL.
@Suite(.serialized) @MainActor struct TrackMonitorBoxTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let hal = CountingHAL()

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
    }

    /// `t1` on channel 1 of `duo`, `t2` on channel 2, `t3` on an app, and `t4` with no route.
    func open() async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let package = folder.url.appending(path: "box.dirigible")
        try await Task.detached {
            var session = Session(sampleRate: 48_000)
            try session.addTrack("t1", name: "Host", layout: .mono)
            try session.addTrack("t2", name: "Guest", layout: .mono)
            try session.addTrack("t3", name: "Call", layout: .mono)
            try session.addTrack("t4", name: "Spare", layout: .mono)
            try session.setRoute(Route.device(uid: "duo", channels: .mono(1)), track: "t1")
            try session.setRoute(Route.device(uid: "duo", channels: .mono(2)), track: "t2")
            try session.setRoute(.app(bundleID: "us.zoom.xos"), track: "t3")
            try session.write(to: package)
        }.value
        let (model, studio, window, view) = try await openLanes(app, package)
        studio.environment = hal.environment
        return (model, studio, window, view)
    }

    // MARK: B2

    /// A click on the Monitor box of t1 monitors t1 only, with no undo entry, and the meter of t1
    /// shows. Track > Monitor Track shows the check mark with t1 selected. A second click turns
    /// it off.
    @Test func aClickMonitorsItsTrackOnly() async throws {
        let (model, studio, window, view) = try await open()

        try clickPoint(try headerBoxPoint(1, row: 0, in: view), in: window)

        #expect(model.listened == ["t1"], "listened: \(model.listened)")
        #expect(!studio.canUndo, "no undo entry")
        await until("the device plays and the meter shows") {
            studio.listeners["duo"] != nil && studio.liveTracks["t1"]?.state == .monitoring
        }
        model.timeline.selection = Selection.none.clickingHeader("t1", command: false, shift: false, in: studio.session)
        #expect(model.listensSelection, "the menu item shows the check mark")
        try clickPoint(try headerBoxPoint(1, row: 0, in: view), in: window)
        #expect(model.listened.isEmpty, "a second click turns it off: \(model.listened)")
        await until("the monitor stops") { studio.listeners.isEmpty && hal.isFree }
        await model.close()
    }
}
