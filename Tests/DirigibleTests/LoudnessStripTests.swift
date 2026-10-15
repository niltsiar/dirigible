import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The loudness strip and its menu item (run 9b criteria 14, 15, and 18). The strip only formats:
/// `Studio.loudness` gives nil M and S when no 1x forward play runs.
@Suite(.serialized) @MainActor struct LoudnessStripTests {
    let folder: TemporaryFolder
    let defaults: UserDefaults
    let suite = "LoudnessStripTests.\(UUID().uuidString)"

    init() throws {
        folder = try TemporaryFolder()
        defaults = try #require(UserDefaults(suiteName: suite))
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    static let playing = LoudnessValues(
        momentary: LUFS(value: -14.2), shortTerm: LUFS(value: -17.44), integrated: LUFS(value: -16.8), truePeak: -0.6,
        seconds: 192)

    func strip() -> LoudnessStrip { LoudnessStrip(frame: NSRect(x: 0, y: 0, width: 1180, height: 28)) }

    // MARK: Criterion 15

    @Test func stripTextsFollowTheValues() {
        let strip = strip()
        strip.show(Self.playing, target: nil, inputs: false, now: 0)
        #expect(
            strip.texts
                == LoudnessTexts(
                    shortTerm: "-17.4", integrated: "-16.8", duration: "3:12", peak: "-0.6", peakOver: true,
                    target: "-16"),
            "\(strip.texts)")
        var quieter = Self.playing
        quieter.truePeak = -1.2
        strip.show(quieter, target: nil, inputs: false, now: 1)
        #expect(strip.texts.peak == "-1.2" && !strip.texts.peakOver, "TP -1.2: \(strip.texts)")
        // The stopped values: nil M and S draw dashes; I and TP stay.
        var stopped = Self.playing
        (stopped.momentary, stopped.shortTerm) = (nil, nil)
        strip.show(stopped, target: nil, inputs: false, now: 2)
        #expect(strip.texts.shortTerm == "\u{2013}" && strip.texts.integrated == "-16.8", "stopped: \(strip.texts)")
        strip.show(.none, target: nil, inputs: false, now: 3)
        #expect(
            strip.texts == LoudnessTexts(target: "-16"), "no values: \(strip.texts)")
        #expect(LoudnessText.duration(3_725) == "1:02:05")

        var live = LiveTrack(state: .recording, droppedFrames: 0, peak: 0.5, shortTerm: LUFS(value: -17.4))
        #expect(
            LoudnessText.header(live) == "-17", "recording header: \(String(describing: LoudnessText.header(live)))")
        live.state = .monitoring
        #expect(LoudnessText.header(live) == "-17")
        live.state = .deviceLost
        #expect(LoudnessText.header(live) == nil, "a lost device shows no number")
    }

    /// The meter measures the stereo mix, so the line is the stereo target of the export preset,
    /// also for a mono export. The podcast preset with a mono layout would give -19.
    @Test func theTargetIsTheStereoPresetValue() {
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let settings = ExportSettings(defaults: defaults)
        #expect(loudnessTarget(defaults.string(forKey: ExportSettings.loudnessKey)).value == -16, "no preference")
        settings.layout = .mono
        settings.loudness = .podcast
        #expect(loudnessTarget(defaults.string(forKey: ExportSettings.loudnessKey)).value == -16, "podcast, mono")
        settings.layout = .stereo
        #expect(loudnessTarget(defaults.string(forKey: ExportSettings.loudnessKey)).value == -16, "podcast, stereo")
        settings.loudness = .ebu
        #expect(loudnessTarget(defaults.string(forKey: ExportSettings.loudnessKey)).value == -23, "EBU")
        settings.loudness = nil
        #expect(loudnessTarget(defaults.string(forKey: ExportSettings.loudnessKey)).value == -16, "Off")
        #expect(loudnessTarget(nil).value == -16, "no defaults")
    }

    // MARK: Criterion 18

    /// 600 ticks at 60 Hz with a new value at each tick: the texts change at most 4 times a
    /// second, the VoiceOver value at most once a second.
    @Test func accessibilityValueChangesOnceASecond() {
        let strip = strip()
        for tick in 0..<600 {
            var values = Self.playing
            values.shortTerm = LUFS(value: -20 + Double(tick % 50) / 10)
            values.integrated = LUFS(value: -18 + Double(tick % 37) / 10)
            values.seconds = Double(tick) / 60
            strip.show(values, target: nil, inputs: false, now: Double(tick) / 60)
        }
        #expect((20...45).contains(strip.textChanges), "text changes: \(strip.textChanges)")
        #expect((1...10).contains(strip.accessibilityChanges), "VoiceOver value changes: \(strip.accessibilityChanges)")
        #expect(strip.isAccessibilityElement() && strip.accessibilityRole() == .levelIndicator)
        #expect(strip.accessibilityLabel() == L10n.loudnessMeter.text)
    }

    /// During a take the strip shows dashes, and its tooltip points to the track headers.
    @Test func aTakeShowsDashesAndTheHeaderTip() {
        let strip = strip()
        strip.layoutSubtreeIfNeeded()
        strip.show(.none, target: nil, inputs: true, now: 0)
        #expect(strip.texts.shortTerm == "\u{2013}")
        #expect(strip.toolTip(at: NSPoint(x: 20, y: 14)) == L10n.loudnessTakeTip.text)
        strip.show(.none, target: nil, inputs: false, now: 1)
        #expect(strip.toolTip(at: NSPoint(x: 20, y: 14)) == L10n.loudnessShortTip.text)
    }

    // MARK: Criterion 14

    @Test func noSessionTurnsTheItemOff() {
        let app = AppDelegate(recordings: nil, defaults: defaults)
        #expect(app.key == nil)
        #expect(app.loudnessItem == (title: .menuViewLoudnessShow, enabled: false), "\(app.loudnessItem)")
    }

    /// A window of one track with a clip of silence, and its strip in the window.
    func open(_ app: AppDelegate, name: String = "a") async throws -> (SessionWindow, Studio) {
        let package = folder.url.appending(path: name)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let model = await app.open(try await timelinePackage(in: package, tracks: 1, seconds: 3, audio: true))
        let studio = try #require(await model.opened() ? model.studio : nil)
        try await fixFreeSpace(model)
        studio.environment.playerOutput = .offline
        await until("the window shows the lanes") { (model.timelineView?.updates ?? 0) > 0 }
        return (model, studio)
    }

    func shown(_ model: SessionWindow) -> Bool { model.loudnessStrip?.window != nil }

    @Test func idleTogglesAndKeepsThePreference() async throws {
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let app = AppDelegate(recordings: nil, defaults: defaults)
        let (model, _) = try await open(app)
        await until("the strip shows") { shown(model) }
        #expect(app.loudnessItem(for: model) == (title: .menuViewLoudnessHide, enabled: true))

        model.toggleLoudness()
        await until("the strip goes") { !shown(model) }
        #expect(app.loudnessItem(for: model) == (title: .menuViewLoudnessShow, enabled: true))
        #expect(defaults.object(forKey: SessionWindow.loudnessKey) as? Bool == false)

        let (second, _) = try await open(app, name: "b")
        #expect(!second.showsLoudness, "a new window takes the preference")
        second.toggleLoudness()
        await until("the strip of the new window shows") { shown(second) }
        await second.close()
        await model.close()
    }

    /// The display tick draws the values of `Studio.loudness`; no SwiftUI body runs. Hide
    /// during a play keeps the play; a hidden strip sets no layer and no text.
    @Test func playDrawsTheValuesAndHideKeepsThePlay() async throws {
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let app = AppDelegate(recordings: nil, defaults: defaults)
        let (model, studio) = try await open(app)
        await until("the strip shows") { shown(model) }
        let strip = try #require(model.loudnessStrip)
        let view = try #require(model.timelineView)
        view.linkProxy?.view = nil
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        try await Task.sleep(for: .milliseconds(200))
        let bodies = model.bodyRuns
        for tick in 0..<60 {
            var values = Self.playing
            values.momentary = LUFS(value: -30 + Double(tick) / 4)
            studio.loudness = values
            view.displayTick()
        }
        #expect(strip.texts.shortTerm == "-17.4", "the tick drew the values: \(strip.texts)")
        #expect(strip.layerChanges > 0, "the bar moved")
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.bodyRuns == bodies, "the ticks ran \(model.bodyRuns - bodies) SwiftUI bodies")
        // `loudnessTick` on the real clock (`PlayTickBenchmark`): a new short-term text at each
        // tick changes the texts at least once and at most 4 times a second. The wait puts the
        // last text change more than 0.25 s back.
        try await Task.sleep(for: .milliseconds(300))
        let (changes, start) = (strip.textChanges, CACurrentMediaTime())
        for tick in 0..<60 {
            var values = Self.playing
            values.shortTerm = LUFS(value: -20 + Double(tick) / 10)
            studio.loudness = values
            view.displayTick()
        }
        let (changed, elapsed) = (strip.textChanges - changes, CACurrentMediaTime() - start)
        #expect(
            changed >= 1 && changed <= Int(elapsed * 4) + 2, "the strip texts changed \(changed) times in \(elapsed) s")

        model.toggleLoudness()
        await until("the strip goes") { strip.window == nil }
        #expect(studio.playback != .stopped, "Hide keeps the play")
        let (texts, layers) = (strip.textChanges, strip.layerChanges)
        for tick in 0..<60 {
            var values = Self.playing
            values.shortTerm = LUFS(value: -20 - Double(tick))
            values.momentary = LUFS(value: -20 - Double(tick))
            studio.loudness = values
            view.displayTick()
        }
        #expect(
            strip.textChanges == texts && strip.layerChanges == layers,
            "a hidden strip: \(strip.textChanges - texts) texts, \(strip.layerChanges - layers) layers")
        await studio.perform(.playStop)
        await model.close()
    }

    /// A take or a monitor after a play: the strip shows dashes in each value cell, not the held
    /// values of the play (criterion 14 (d), decision 0033; code gate 1, K1).
    @Test(arguments: ["take", "monitor"])
    func metersOfTheInputsShowDashes(_ path: String) async throws {
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let app = AppDelegate(recordings: nil, defaults: defaults)
        let (model, studio) = try await open(app)
        await until("the strip shows") { shown(model) }
        let strip = try #require(model.loudnessStrip)
        let view = try #require(model.timelineView)
        view.linkProxy?.view = nil
        studio.loudness = Self.playing
        view.displayTick()
        #expect(strip.texts.integrated == "-16.8", "the play values: \(strip.texts)")

        if path == "take" {
            try LiveTake.begin(studio, tracks: ["t1"], at: .zero, take: 1)
        } else {
            studio.liveTracks = ["t1": LiveTrack(state: .monitoring, droppedFrames: 0, peak: 0)]
        }
        // The texts change at most 4 times a second.
        await until("\(path): the strip shows dashes") {
            view.displayTick()
            return strip.texts.integrated == LoudnessText.dash
        }
        #expect(strip.texts == LoudnessTexts(target: "-16"), "\(path): \(strip.texts)")
        if path == "take" {
            studio.transport = .idle
            _ = try? studio.edit(ripple: false) { s throws(SessionError) in try s.setRecording(nil) }
        }
        studio.liveTracks = [:]
        await model.close()
    }

    /// Input Levels is a meter only (decision 0015): during a play the output is the play mix,
    /// so the strip shows the play values (code gate 2, J1).
    @Test func aPlayDuringAMonitorShowsThePlayValues() async throws {
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let app = AppDelegate(recordings: nil, defaults: defaults)
        let (model, studio) = try await open(app)
        await until("the strip shows") { shown(model) }
        let strip = try #require(model.loudnessStrip)
        let view = try #require(model.timelineView)
        view.linkProxy?.view = nil
        studio.liveTracks = ["t1": LiveTrack(state: .monitoring, droppedFrames: 0, peak: 0)]
        view.displayTick()
        #expect(strip.texts.integrated == LoudnessText.dash, "a monitor with no play: \(strip.texts)")
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        try #require(studio.playback != .stopped, "the play runs")
        studio.loudness = Self.playing
        await until("the strip shows the play values") {
            view.displayTick()
            return strip.texts.integrated == "-16.8"
        }
        #expect(strip.texts.shortTerm == "-17.4", "a play during a monitor: \(strip.texts)")
        await studio.perform(.playStop)
        studio.liveTracks = [:]
        await model.close()
    }

    /// `show` with the inputs of the last call does nothing, but a text that the 4 Hz limit held
    /// back still comes at the next tick.
    @Test func aHeldTextComesWithTheSameValues() {
        let strip = strip()
        var quieter = Self.playing
        quieter.shortTerm = LUFS(value: -30)
        strip.show(Self.playing, target: nil, inputs: false, now: 0)
        strip.show(quieter, target: nil, inputs: false, now: 0.1)
        #expect(strip.texts.shortTerm == "-17.4", "the limit holds the text back")
        strip.show(quieter, target: nil, inputs: false, now: 0.3)
        #expect(
            strip.texts.shortTerm == "-30.0" && strip.textChanges == 2,
            "the held text came: \(strip.texts), \(strip.textChanges)")
    }
}
