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

    /// `t1` on channel 1 of `duo`, `t2` on channel 2, `t3` on an app, `t4` with no route, and
    /// `t5` on a device that is not connected.
    func open() async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let package = folder.url.appending(path: "box.dirigible")
        try await Task.detached {
            var session = Session(sampleRate: 48_000)
            try session.addTrack("t1", name: "Host", layout: .mono)
            try session.addTrack("t2", name: "Guest", layout: .mono)
            try session.addTrack("t3", name: "Call", layout: .mono)
            try session.addTrack("t4", name: "Spare", layout: .mono)
            try session.addTrack("t5", name: "Lost", layout: .mono)
            try session.setRoute(Route.device(uid: "duo", channels: .mono(1)), track: "t1")
            try session.setRoute(Route.device(uid: "duo", channels: .mono(2)), track: "t2")
            try session.setRoute(.app(bundleID: "us.zoom.xos"), track: "t3")
            try session.setRoute(Route.device(uid: "gone", channels: .mono(1)), track: "t5")
            try session.write(to: package)
        }.value
        let (model, studio, window, view) = try await openLanes(app, package)
        studio.environment = hal.environment
        return (model, studio, window, view)
    }

    /// Sets the transport and waits until the rows read it: they take it at a later run-loop turn.
    func setTransport(_ transport: Studio.Transport, _ model: SessionWindow, _ studio: Studio, _ window: NSWindow)
        async
    {
        let runs = model.headerRuns.rows
        studio.transport = transport
        await until("the rows take the transport") {
            drawNow(window)
            return model.headerRuns.rows > runs
        }
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

    // MARK: B3

    /// The Monitor box of t1 is green only when t1 is monitored; the box of t2 stays with no
    /// green. In Light, as `HeaderRowTests.armRed`. The rows draw the new state at a later run-loop turn,
    /// so the test waits for a row body, then for the end of a pass, before the capture.
    @Test func theMonitorBoxIsGreenOnlyWhenOn() async throws {
        let (model, _, window, view) = try await open()
        window.appearance = NSAppearance(named: .aqua)
        await until("the rows draw the first state") {
            drawNow(window)
            return model.headerRuns.rows > 0
        }
        func green() async throws -> [Int] {
            window.orderFront(nil)
            drawNow(window)
            await runLoopPass()
            let capture = try await TimelineColorTests.capture(window)
            return try (0...1).map { row in
                let box = try headerBoxRows(in: view)[row][1]
                return try TimelineRulerTests.pixels(of: box, capture, window).filter(Self.isGreen).count
            }
        }
        #expect(try await green() == [0, 0], "no green with the monitor off")
        let runs = model.headerRuns.rows
        model.setListen(true, track: "t1")
        await until("the rows draw the Monitor box") {
            drawNow(window)
            return model.headerRuns.rows > runs
        }
        let on = try await green()
        #expect(on[0] > 20 && on[1] == 0, "green in the box of t1 only: \(on)")
        await model.close()
    }

    /// True for the systemGreen fill of an on Monitor box.
    static func isGreen(_ pixel: UInt32) -> Bool {
        let (r, g, b) = (pixel >> 16 & 0xFF, pixel >> 8 & 0xFF, pixel & 0xFF)
        return g > 150 && r < 110 && b < 130
    }

    // MARK: B4

    /// During a take the Monitor box takes a click, on and off; R stays disabled.
    @Test func theBoxWorksDuringATake() async throws {
        let (model, studio, window, view) = try await open()
        await setTransport(.recording(take: 1), model, studio, window)
        try #require(!model.canEdit, "the take disables R, M, and S")
        let armed = model.armed
        try clickPoint(try headerBoxPoint(1, row: 0, in: view), in: window)
        #expect(model.listened == ["t1"], "a click during a take monitors t1: \(model.listened)")
        try clickPoint(try headerBoxPoint(0, row: 1, in: view), in: window)
        #expect(model.armed == armed, "R takes no click during a take: \(model.armed)")
        try clickPoint(try headerBoxPoint(1, row: 0, in: view), in: window)
        #expect(model.listened.isEmpty, "a second click turns it off: \(model.listened)")
        await setTransport(.idle, model, studio, window)
        await model.close()
    }

    // MARK: B5, B6, B7

    /// An app track has no Monitor box but keeps its slot, so its M is in the M column of a
    /// device row.
    @Test func anAppTrackKeepsTheColumns() async throws {
        let (model, _, _, view) = try await open()
        let rows = try headerBoxRows(in: view)
        try #require(rows.count == 5, "five rows: \(rows)")
        #expect(rows[2].count == 3, "R, M, and S in the app row: \(rows[2])")
        #expect(rows[2][1].minX == rows[0][2].minX, "M of the app row is in the M column")
        await model.close()
    }

    /// A track with no route shows the box, disabled: a click does not monitor it.
    @Test func noRouteDisablesTheBox() async throws {
        let (model, _, window, view) = try await open()
        try clickPoint(try headerBoxPoint(1, row: 3, in: view), in: window)
        #expect(model.listened.isEmpty, "no monitor with no route: \(model.listened)")
        try clickPoint(try headerBoxPoint(1, row: 0, in: view), in: window)
        #expect(model.listened == ["t1"], "control: the box of a device track takes the click")
        await model.close()
    }

    /// A device track whose device is not connected keeps an enabled box: the monitor waits for
    /// the device, as Track > Monitor Track does.
    @Test func aMissingDeviceKeepsTheBox() async throws {
        let (model, _, window, view) = try await open()
        try clickPoint(try headerBoxPoint(1, row: 4, in: view), in: window)
        #expect(model.listened == ["t5"], "the missing device track is monitored: \(model.listened)")
        await model.close()
    }

    /// The box follows the rule of the menu item (code gate round 1, item 4): only in the open
    /// phase, and only for a device track.
    @Test func theBoxActsOnlyInAnOpenWindow() async throws {
        let (model, _, _, _) = try await open()
        model.setListen(true, track: "t3")
        #expect(model.listened.isEmpty, "an app track does not listen: \(model.listened)")
        let closing = Task { await model.close() }
        await until("the window is closing") {
            if case .closing = model.phase { true } else { false }
        }
        model.setListen(true, track: "t1")
        model.setListen(true, track: "t1", all: true)
        #expect(model.listened.isEmpty, "a closing window does not listen: \(model.listened)")
        await closing.value
    }

    // MARK: B8

    /// Option-click sets every device track to the new state; the app track and the track with no
    /// route do not change. The view gives `all` from the modifier flags of the click
    /// (`TrackToggles.isOptionClick`); the on-screen check covers that part.
    @Test func anOptionClickSetsEveryDeviceTrack() async throws {
        let (model, _, _, _) = try await open()
        model.setListen(true, track: "t1", all: true)
        #expect(model.listened == ["t1", "t2", "t5"], "every device track: \(model.listened)")
        model.setListen(false, track: "t1", all: true)
        #expect(model.listened.isEmpty, "all off: \(model.listened)")
        await model.close()
    }

    /// A click event with Option that is not the current event of the app (as an AX press) sets
    /// only its track.
    @Test func aPressSetsOneTrack() async throws {
        let (model, _, window, view) = try await open()
        try clickPoint(try headerBoxPoint(1, row: 0, in: view), in: window, flags: .option)
        #expect(model.listened == ["t1"], "one track: \(model.listened)")
        await model.close()
    }

    // MARK: B9

    /// The VoiceOver label names the track, and the help gives the key and the Option-click, in
    /// English and in Spanish.
    @Test func theBoxNamesTheTrack() throws {
        let (en, es) = (try stringsTable("en"), try stringsTable("es"))
        #expect(String(format: en[L10n.trackMonitorLabel.rawValue] ?? "", "Host") == "Monitor Host")
        #expect(String(format: es[L10n.trackMonitorLabel.rawValue] ?? "", "Host") == "Monitorizar Host")
        for table in [en, es] {
            let help = table[L10n.trackMonitorHelp.rawValue] ?? ""
            // Code gate round 1, item 6: the key comes from `MenuKeys`, not from a copy in the table.
            #expect(help.contains("(%@)") && help.contains("Op"), "the key and the Option-click: \(help)")
        }
        let help = String(format: en[L10n.trackMonitorHelp.rawValue] ?? "", keyText(MenuKeys.monitorTrack))
        #expect(help.hasPrefix("Monitor Track (⌃⌘M):"), "the help with the key: \(help)")
    }

    // MARK: Code gate round 1, item 1

    /// A loopback has its own text; a meter fault shows first, as for the quiet text.
    @Test func aLoopbackHasItsOwnText() throws {
        #expect(listenQuietText(state: nil, quiet: false, loopback: true) == L10n.trackListenLoopback.text)
        #expect(listenQuietText(state: nil, quiet: true, loopback: false) == L10n.trackListenQuiet.text)
        #expect(listenQuietText(state: nil, quiet: false, loopback: false) == nil)
        let (en, es) = (try stringsTable("en"), try stringsTable("es"))
        #expect(en[L10n.trackListenLoopback.rawValue] != nil && es[L10n.trackListenLoopback.rawValue] != nil)
    }

    // MARK: B24

    /// A route edit that leaves a listened track with no device route ends its monitor: Route >
    /// None, an app route, and an Undo of a route set. The filter runs in the onChange Task, so
    /// each assert after an edit waits.
    @Test func aClearedRouteEndsTheMonitor() async throws {
        let (model, studio, _, _) = try await open()
        model.setListen(true, track: "t1")
        model.setListen(true, track: "t2")
        await until("both monitor") { studio.listeners["duo"] != nil }
        model.setRoute(nil, device: nil, track: "t1")
        model.setAppRoute("us.zoom.xos", track: "t2")
        await until("no track stays listened") { model.listened.isEmpty }
        #expect(model.listened.isEmpty, "Route > None and an app route end the monitor: \(model.listened)")

        model.setRoute(.mono(1), device: AppRouteMenuTests.duo, track: "t4")
        await until("t4 has a device route") {
            if case .device = studio.session.track("t4")?.route { true } else { false }
        }
        model.setListen(true, track: "t4")
        await until("t4 monitors") { model.listened == ["t4"] && studio.listeners["duo"] != nil }
        model.undo()
        await until("the Undo ends the monitor of t4") { model.listened.isEmpty }
        #expect(model.listened.isEmpty, "an Undo of the route ends the monitor: \(model.listened)")
        await model.close()
    }
}
