import AppKit
import DirigibleCore
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Criterion P11 (run 2026-10-28-pre-roll): Record > Record with Pre-roll has the key P, a plain
/// key. One case for each start state: the key goes to text first, as the other plain keys do.
@Suite(.serialized) @MainActor struct PreRollKeyTests {
    let folder: TemporaryFolder
    let defaults: UserDefaults
    let app: AppDelegate
    let hal = CountingHAL()

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
        defaults = try #require(UserDefaults(suiteName: "preroll-key-\(UUID().uuidString)"))
        app = AppDelegate(recordings: nil, defaults: defaults)
    }

    func event(repeated: Bool = false, in window: NSWindow? = nil) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0,
            context: nil, characters: "p", charactersIgnoringModifiers: "p", isARepeat: repeated, keyCode: 35)!
    }

    /// A window of a 6 s package with track `t1` on the fake device, armed.
    func open(audio: Bool = false) async throws -> (SessionWindow, Studio, NSWindow) {
        let package = try await timelinePackage(in: folder.url, tracks: 1, seconds: 6, audio: audio, device: "duo")
        let (model, studio, window, _) = try await openLanes(app, package)
        studio.environment = hal.environment
        model.armed = ["t1"]
        window.makeFirstResponder(nil)
        return (model, studio, window)
    }

    func end(_ model: SessionWindow, _ studio: Studio) async {
        await model.stop()
        await until(limit: .seconds(30), "the take ends") { studio.transport == .idle }
        await model.close()
    }

    @Test func theItemHasTheKeyP() {
        #expect(MenuKeys.preRoll == KeyboardShortcut("p", modifiers: []))
        #expect(MenuKeys.all.contains(MenuKeys.preRoll))
        #expect(WindowCommand.recordPreRoll.menuItem.title == .menuRecordPreRoll)
        #expect(WindowCommand.recordPreRoll.menuItem.key == MenuKeys.preRoll)
    }

    /// Idle with an armed track: the take starts at the playhead with the pre-roll of the preference.
    @Test func pStartsAPreRollTake() async throws {
        defaults.set(2, forKey: AppDelegate.preRollKey)
        let app = AppDelegate(recordings: nil, defaults: defaults)
        let (model, studio, window, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 1, seconds: 6, device: "duo"))
        studio.environment = hal.environment
        model.armed = ["t1"]
        window.makeFirstResponder(nil)
        await studio.perform(.seek(.frame(240_000)))

        app.recordPreRoll(event: event(in: window), in: window)

        await until(limit: .seconds(30), "the take starts") { studio.transport == .recording(take: 1) }
        let recording = try #require(studio.session.recording)
        #expect(recording.isPreRoll && recording.playheadFrame == 240_000 && recording.armedTracks == ["t1"])
        let start = try #require(await studio.play.player?.reading().realStart)
        let lead = Double(recording.takeStartHostTimeNanos - start) / 1e9
        #expect((2.0..<2.2).contains(lead), "the pre-roll was \(lead) s, not the 2 s of the preference")
        await end(model, studio)
    }

    /// Playing: the play stops and the take starts at the Player position, as Command-R does.
    @Test func pWhilePlayingStartsTheTakeAtThePlayerPosition() async throws {
        let (model, studio, window) = try await open(audio: true)
        await studio.perform(.seek(.frame(48_000)))
        await studio.perform(.playStop)
        _ = await studio.renderOffline(frames: 9_600)
        await until(limit: .seconds(10), "the play moves") { studio.playhead > 48_000 }

        app.recordPreRoll(event: event(in: window), in: window)

        await until(limit: .seconds(30), "the take starts") { studio.transport == .recording(take: 1) }
        let recording = try #require(studio.session.recording)
        #expect(recording.isPreRoll && recording.playheadFrame > 48_000, "T is the Player position")
        await end(model, studio)
    }

    /// Negative control: a focused text field gets "p", and no take starts.
    @Test func pInATextFieldTypesAndStartsNoTake() async throws {
        let (model, studio, window) = try await open()
        let editor = try await focusName(in: window)

        app.recordPreRoll(event: event(in: window), in: window)

        #expect(editor.string == "p", "the field got \(editor.string)")
        try await Task.sleep(for: .milliseconds(200))
        #expect(studio.transport == .idle)
        await model.close()
    }

    /// The Transcript pane takes the transport keys: the take starts, and the pane gets no text.
    @Test func pInTheTranscriptPaneStartsTheTake() async throws {
        let panes = try TranscriptPaneTests()
        let (model, studio, window, _) = try await panes.open(try await panes.package())
        model.showTranscript()
        let pane = try await panes.waitForPane(window)
        studio.environment = hal.environment
        try studio.edit(ripple: false) { s throws(SessionError) in
            try s.setRoute(Route.device(uid: "duo", channels: .mono(1)), track: "t1")
        }
        model.armed = ["t1"]
        let text = pane.string

        panes.app.recordPreRoll(event: event(in: window), in: window)

        await until(limit: .seconds(30), "the take starts") { studio.transport == .recording(take: 1) }
        #expect(studio.session.recording?.isPreRoll == true && pane.string == text)
        await end(model, studio)
    }

    /// No armed track: the refusal of Record, with no take. The item is never disabled, so it beeps.
    @Test func pWithNoArmedTrackBeepsAndStartsNoTake() async throws {
        let (model, studio, window) = try await open()
        model.armed = []
        var beeps = 0
        model.beep = { beeps += 1 }

        app.recordPreRoll(event: event(in: window), in: window)

        try await Task.sleep(for: .milliseconds(300))
        #expect(studio.transport == .idle && studio.session.recording == nil)
        #expect(beeps == 1)
        await model.close()
    }

    /// A take or a finalize runs: the key starts nothing and changes nothing, and gives the busy beep.
    @Test func pDuringATakeDoesNothing() async throws {
        let (model, studio, window) = try await open()
        studio.transport = .recording(take: 7)
        defer { studio.transport = .idle }
        var beeps = 0
        model.beep = { beeps += 1 }

        app.recordPreRoll(event: event(in: window), in: window)

        try await Task.sleep(for: .milliseconds(300))
        #expect(studio.transport == .recording(take: 7) && studio.session.recording == nil)
        #expect(beeps == 1)
        await model.close()
    }

    /// A held P starts one take: a key repeat does nothing.
    @Test func aHeldPStartsNoSecondTake() async throws {
        let (model, studio, window) = try await open()

        app.recordPreRoll(event: event(repeated: true, in: window), in: window)

        try await Task.sleep(for: .milliseconds(300))
        #expect(studio.transport == .idle)
        await model.close()
    }

    /// No session window: the key does nothing, and the menu item has no window to start a take.
    @Test func pWithNoSessionWindowDoesNothing() {
        app.key = nil
        app.recordPreRoll(event: event(), in: nil)
        #expect(app.key == nil)
    }
}
