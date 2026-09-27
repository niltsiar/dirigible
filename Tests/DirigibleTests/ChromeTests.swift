import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The time text of the toolbar (ui-shell criterion A19).
struct TimeTextTests {
    @Test func theTimeTextHasTenthsDuringPlayAndMillisecondsWhenStopped() {
        #expect(timeDisplayText(178_725_888, rate: 48_000, playing: false) == "1:02:03.456")
        #expect(timeDisplayText(178_725_888, rate: 48_000, playing: true) == "1:02:03.4")
        #expect(timeDisplayText(47_999, rate: 48_000, playing: false) == "0:00:00.999")
        #expect(timeDisplayText(47_999, rate: 48_000, playing: true) == "0:00:00.9")
        #expect(timeDisplayText(96_000, rate: 48_000, playing: false) == "0:00:02.000")
        #expect(timeDisplayText(Frames(48_000 * 3600 + 24), rate: 48_000, playing: false) == "1:00:00.000")
        #expect(timeDisplayText(Frames(48_000 * 61 + 12_345), rate: 48_000, playing: false) == "0:01:01.257")
        #expect(timeDisplayText(0, rate: 48_000, playing: true) == "0:00:00.0")
    }
}

/// The chrome loop on a real session window (ui-shell criteria A9, A17 part, A19 to A21): the
/// item states, the push-on buttons, the time display, and no SwiftUI body during a play.
@Suite(.serialized) @MainActor struct ChromeTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let hal = CountingHAL()
    static let forward = Playback.playing(Shuttle(direction: .forward, rate: .one))

    init() throws {
        folder = try TemporaryFolder()
        // The "prefer tabs" preference of the Mac is a shared resource (the tdd skill).
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// A window of `tracks` tracks on channel 1 of `duo`, each with a clip of `seconds` of silence,
    /// with the counting HAL and the offline Player, after the toolbar has its items.
    func open(tracks: Int = 1, seconds: Int = 10) async throws -> (SessionWindow, Studio, SessionChrome) {
        let url = try await timelinePackage(
            in: folder.url, tracks: tracks, seconds: seconds, audio: true, device: "duo")
        let model = await app.open(url)
        let studio = try #require(await model.opened() ? model.studio : nil)
        studio.environment = hal.environment
        studio.environment.playerOutput = .offline
        let chrome = try #require(model.chrome)
        await until("the toolbar has its items") { chrome.time != nil }
        return (model, studio, chrome)
    }

    func item(_ id: ToolbarItemID, _ chrome: SessionChrome) throws -> NSToolbarItem {
        try #require(chrome.toolbar.items.first { $0.itemIdentifier == id.identifier }, "\(id)")
    }

    func button(_ id: ToolbarItemID, _ chrome: SessionChrome) throws -> NSButton {
        try #require(try item(id, chrome).view as? NSButton, "\(id)")
    }

    /// The enabled items and the push-on items that are on, as the toolbar shows them.
    func shown(_ chrome: SessionChrome) -> (enabled: Set<ToolbarItemID>, on: Set<ToolbarItemID>) {
        var enabled: Set<ToolbarItemID> = []
        var on: Set<ToolbarItemID> = []
        for item in chrome.toolbar.items {
            guard let id = ToolbarItemID(rawValue: item.itemIdentifier.rawValue), id != .time else { continue }
            if item.isEnabled { enabled.insert(id) }
            if (item.view as? NSButton)?.state == .on { on.insert(id) }
        }
        return (enabled, on)
    }

    /// Waits (5 s) until the toolbar shows `enabled` and `on` for the items of `ids`, then expects it.
    func expectShown(
        _ chrome: SessionChrome, _ phase: String, ids: Set<ToolbarItemID>, enabled: Set<ToolbarItemID>,
        on: Set<ToolbarItemID>
    ) async {
        let matches = {
            let now = shown(chrome)
            return now.enabled.intersection(ids) == enabled && now.on.intersection(ids) == on
        }
        await until(limit: .seconds(5), "\(phase): the toolbar follows") { matches() }
        let now = shown(chrome)
        #expect(now.enabled.intersection(ids) == enabled, "\(phase): enabled")
        #expect(now.on.intersection(ids) == on, "\(phase): on")
    }

    /// Renders the offline Player at 48 kHz in real time for `seconds`, so the poll moves the
    /// playhead as a real play does.
    func renderRealTime(_ studio: Studio, seconds: Double) async throws {
        let start = ContinuousClock.now
        var rendered = 0
        while ContinuousClock.now - start < .seconds(seconds) {
            try await Task.sleep(for: .milliseconds(10))
            let due = Int((ContinuousClock.now - start) / .seconds(1) * 48_000)
            if due > rendered {
                _ = await studio.renderOffline(frames: due - rendered)
                rendered = due
            }
        }
    }

    // MARK: A9

    @Test func theItemsFollowTheWindowState() async throws {
        let (model, studio, chrome) = try await open()
        let ids: Set<ToolbarItemID> = [.record, .stop, .play, .monitor, .addTrack, .split, .zoomIn]
        let idle: Set<ToolbarItemID> = [.record, .play, .monitor, .addTrack, .split, .zoomIn]
        await expectShown(chrome, "idle", ids: ids, enabled: idle, on: [])

        model.monitoring = true
        await expectShown(chrome, "monitor", ids: ids, enabled: idle, on: [.monitor])
        model.monitoring = false
        await expectShown(chrome, "monitor off", ids: ids, enabled: idle, on: [])

        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        await expectShown(chrome, "play", ids: ids, enabled: idle.union([.stop]), on: [.play])
        await studio.perform(.playStop)
        await expectShown(chrome, "play stopped", ids: ids, enabled: idle, on: [])

        await model.record()
        await expectShown(chrome, "take", ids: ids, enabled: [.record, .stop, .monitor], on: [.record])
        await hal.feed(seconds: 0.2)
        await model.stop()
        await until("the finalize ends") { studio.transport == .idle }
        await expectShown(chrome, "after the take", ids: ids, enabled: idle, on: [])

        // A play that ends at the session end: no user event, the poll ends it.
        await studio.perform(.seek(.frame(studio.session.end - 2_400)))
        await studio.perform(.playStop)
        await expectShown(chrome, "play to the end", ids: ids, enabled: idle.union([.stop]), on: [.play])
        _ = await studio.renderOffline(frames: 9_600)
        await until(limit: .seconds(10), "the play ends at the session end") { studio.playback == .stopped }
        await until(limit: .seconds(1), "Play goes off within 1 s") { !shown(chrome).on.contains(.play) }
        #expect(!shown(chrome).on.contains(.play), "Play is on after the end")
        #expect(!shown(chrome).enabled.contains(.stop), "Stop is on after the end")
        await model.close()
    }

    /// Plan gate 2 item 1: an enabled Record whose start the access refuses. The click flips the
    /// button before its action; the action runs and Record stays off, with no loop turn.
    @Test func aRefusedRecordClickLeavesRecordOff() async throws {
        let (model, studio, chrome) = try await open()
        studio.environment.microphoneAccess = { .denied }
        let record = try button(.record, chrome)
        await until("Record is enabled") { record.isEnabled }
        try #require(record.isEnabled)

        record.performClick(nil)

        #expect(record.state == .off, "Record is lit")
        await until("the Record action runs") { model.alert == .microphone(.denied) }
        #expect(record.state == .off, "Record is lit after the refusal")
        #expect(studio.transport == .idle)
        await model.close()
    }

    /// A Record click during a take does nothing: Record stays on, with no loop turn.
    @Test func aRecordClickDuringATakeLeavesRecordOn() async throws {
        let (model, studio, chrome) = try await open()
        let record = try button(.record, chrome)
        await model.record()
        await until("Record is on during the take") { record.state == .on }
        let turns = chrome.turns

        record.performClick(nil)

        #expect(chrome.turns == turns, "a loop turn ran")
        #expect(record.state == .on, "Record is off during the take")
        #expect(model.canStop, "the take goes on")
        await hal.feed(seconds: 0.2)
        await model.stop()
        await until("the finalize ends") { studio.transport == .idle }
        await model.close()
    }

    /// A Play click at the session end changes nothing: the play start and its end run a loop
    /// turn, and Play is off after them.
    @Test func aPlayClickAtTheSessionEndLeavesPlayOff() async throws {
        let (model, studio, chrome) = try await open()
        await studio.perform(.seek(.end))
        let play = try button(.play, chrome)
        await until("Play is enabled") { play.isEnabled }
        let turns = chrome.turns

        play.performClick(nil)

        #expect(play.state == .off, "Play is lit at the click")
        await until("the play start runs a loop turn") { chrome.turns > turns }
        #expect(play.state == .off, "Play is lit after the loop turn")
        #expect(studio.playback == .stopped)
        await model.close()
    }

    /// Plan gate 2 item 2: each loop turn compares a push-on button with its control state, not
    /// with the last state.
    @Test func applyCorrectsAButtonStateSetOutOfBand() async throws {
        let (model, _, chrome) = try await open()
        let record = try button(.record, chrome)
        await until("Record is enabled") { record.isEnabled }
        record.state = .on
        let turns = chrome.turns

        model.addTrack()

        await until("Add Track runs a loop turn") { chrome.turns > turns }
        #expect(record.state == .off, "Record is lit with no take")
        await model.close()
    }

    // MARK: A17 part

    /// Plan gate 1 item 2: an arm change while stopped shows the record-over warning after one
    /// loop turn. The display link is off, so no display tick writes it.
    @Test func anArmChangeWhileStoppedShowsRecordOver() async throws {
        let (model, studio, _) = try await open(tracks: TimelineViewTests.tracksThatDoNotFit, seconds: 20)
        await until("the window shows the lanes") { model.timelineView?.window != nil }
        let view = try #require(model.timelineView)
        view.viewWillMove(toWindow: nil)
        model.armed = []
        await studio.perform(.seek(.frame(100_000)))
        await until("the lanes publish the lanes in view") { model.timeline.visible != nil }
        let last = TrackID("t\(TimelineViewTests.tracksThatDoNotFit)")
        try #require(model.timeline.visible?.lanes.contains(TimelineViewTests.tracksThatDoNotFit - 1) == false)
        #expect(!model.shown.recordOver)

        model.armed = [last]

        await until(limit: .seconds(5), "the warning shows after the arm") { model.shown.recordOver }
        #expect(model.shown.recordOver)
        model.armed = ["t1"]
        await until(limit: .seconds(5), "the warning goes for a lane in view") { !model.shown.recordOver }
        #expect(!model.shown.recordOver)
        await model.close()
    }

    // MARK: A19, A20

    @Test func theTimeDisplayKeepsItsWidth() async throws {
        let (model, _, chrome) = try await open()
        let time = try #require(chrome.time)
        let window = try #require(model.window)
        var frames: [NSRect] = []
        for text in ["0:00:00.000", "0:00:00.0", "10:00:00.000", "1:11:11.111"] {
            time.text = text
            window.layoutIfNeeded()
            frames.append(time.frame)
        }
        #expect(Set(frames.map(\.width)).count == 1, "\(frames)")
        #expect(time.accessibilityLabel() == L10n.toolbarTime.text)
        #expect(time.accessibilityValue() as? String == "1:11:11.111")
        await model.close()
    }

    /// At 1x and at 2x the time text changes 5 to 11 times a second, and the play goes on. After
    /// the stop it has milliseconds; a seek while stopped changes it. In a full run other suites
    /// hold the main actor, so fewer polls run: the lower bound is 5 or the loop turns less one,
    /// the smaller.
    @Test func thePlayChangesTheTimeAtMostTenTimesASecond() async throws {
        let (model, studio, chrome) = try await open()
        let time = try #require(chrome.time)
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)

        for command in [nil, TransportCommand.forward] {
            if let command { await studio.perform(command) }
            let (changes, turns, playhead) = (time.textChanges, chrome.turns, studio.playhead)
            try await renderRealTime(studio, seconds: 1)
            let (count, polls) = (time.textChanges - changes, chrome.turns - turns)
            #expect(count <= 11, "\(studio.playback): \(count) changes in 1 s")
            #expect(count >= min(5, polls - 1), "\(studio.playback): \(count) changes in 1 s, \(polls) loop turns")
            #expect(studio.playback != .stopped, "the play goes on")
            #expect(studio.playhead > playhead, "the play moved the playhead")
        }
        #expect(studio.playback == .playing(Shuttle(direction: .forward, rate: .two)))

        await studio.perform(.pause)
        await until("milliseconds after the stop") {
            time.text == timeDisplayText(studio.playhead, rate: 48_000, playing: false)
        }
        #expect(time.text.split(separator: ".").last?.count == 3, "\(time.text)")
        await studio.perform(.seek(.frame(12_345)))
        await until("a seek while stopped changes the text") { time.text == "0:00:00.257" }
        #expect(time.text == "0:00:00.257")
        await model.close()
    }

    // MARK: A21

    /// During 1 s of play, with an armed track, a clip at the playhead, and Record possible, no
    /// SwiftUI body of the window content runs, and the lanes get no `updateNSView`.
    @Test func aPlayRunsNoSwiftUIBody() async throws {
        let (model, studio, chrome) = try await open(tracks: 2, seconds: 3)
        await until("the window shows the lanes") { (model.timelineView?.updates ?? 0) > 0 }
        let view = try #require(model.timelineView)
        let time = try #require(chrome.time)
        await studio.perform(.seek(.start))
        try #require(model.canRecord && !model.armed.isEmpty)
        try #require(studio.session.hasClip(at: 0, on: ["t1"]))
        await studio.perform(.playStop)
        let (bodies, updates, changes) = (model.bodyRuns, view.updates, time.textChanges)

        try await renderRealTime(studio, seconds: 1)

        #expect(time.textChanges > changes, "the play reached the chrome")
        #expect(model.bodyRuns == bodies, "a play ran \(model.bodyRuns - bodies) SwiftUI bodies")
        #expect(view.updates == updates)
        #expect(studio.playback == Self.forward, "the play goes on")
        await studio.perform(.playStop)
        await model.close()
    }
}
