import AVFoundation
import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The banner of an import or a paste with VoiceOver and the keyboard (decision 0042, C21,
/// `ui-panel.md` item 7): Command-period is Cancel, and the banner is announced once. The label of
/// the bar is an on-screen check: the accessibility tree of the SwiftUI host is empty in some host
/// states of a test process (BannerTests, A14). The record-over warning is announced once for each
/// key: the tracks of the warning in lane order (run timeline-clarity, L1-S3, C5).
@Suite(.serialized) @MainActor struct SessionBannerAccessibilityTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws {
        folder = try TemporaryFolder()
        let source = folder.url.appending(path: "Voice.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000))
        buffer.frameLength = 192_000
        try AVAudioFile(forWriting: source, settings: format.settings).write(from: buffer)
        app.chooseImport = { _, done in done(source) }
    }

    /// A window whose import holds at its first block until `hold` gets a signal.
    func importing() async throws -> (SessionWindow, Studio, NSWindow, DispatchSemaphore) {
        let package = try await timelinePackage(in: folder.url, tracks: 2, seconds: 2, audio: true)
        let (model, studio, window, _) = try await openLanes(app, package)
        studio.environment.playerOutput = .offline
        let hold = DispatchSemaphore(value: 0)
        let entered = LockedFlag()
        studio.environment.importStep = {
            guard !entered.value else { return }
            entered.value = true
            _ = hold.wait(timeout: .now() + 30)
        }
        model.run(TimelineCommand.importAudio)
        await until("the import holds") { entered.value }
        return (model, studio, window, hold)
    }

    /// C21a: Command-period ends the run as Cancel does, with the focus on the lanes and in a field.
    @Test(arguments: [false, true])
    func commandPeriodCancelsAnImport(inField: Bool) async throws {
        let (model, studio, window, hold) = try await importing()
        let before = studio.session
        if inField { _ = try await focusName(in: window) }

        let event = commandKey(".", code: 47, in: window)
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
        hold.signal()
        await until("the import ends") { model.importJob == nil }

        #expect(studio.session == before && model.alert == nil, "Command-period cancels and shows nothing")
        await model.close()
    }

    /// C21c: the start of the run announces the banner text once.
    @Test func theStartOfAnImportIsAnnounced() async throws {
        let package = try await timelinePackage(in: folder.url, tracks: 1, seconds: 2, audio: true)
        let (model, _, _, _) = try await openLanes(app, package)
        var heard: [String] = []
        model.chrome?.announce = { text, _ in heard.append(text) }

        model.run(TimelineCommand.importAudio)
        await until("the import ends") { model.importJob == nil }

        #expect(heard == [L10n.importBanner.format("Voice.wav")])
        await model.close()
    }

    // MARK: The record-over warning

    /// A window of 20 tracks of 20 s with the display link off and no armed track. The announcements
    /// go to the returned box.
    func warningWindow() async throws -> (SessionWindow, Studio, SessionChrome, TimelineScrollView, Heard) {
        let tracks = TimelineViewTests.tracksThatDoNotFit
        let package = try await timelinePackage(in: folder.url, tracks: tracks, seconds: 20, audio: true)
        let (model, studio, _, view) = try await openLanes(app, package)
        studio.environment.playerOutput = .offline
        view.viewWillMove(toWindow: nil)
        let chrome = try #require(model.chrome)
        let heard = Heard()
        chrome.announce = { text, priority in heard.lines.append("\(priority.rawValue) \(text)") }
        return (model, studio, chrome, view, heard)
    }

    final class Heard {
        var lines: [String] = []
    }

    /// C5: a warning is announced when its key is new. The key is the tracks of the warning. A seek
    /// inside the same clip, a disarm, and the same arm again announce nothing; a second hidden armed
    /// track is a new key.
    @Test func theRecordOverWarningIsAnnouncedOncePerKey() async throws {
        let (model, studio, chrome, _, heard) = try await warningWindow()
        let high = NSAccessibilityPriorityLevel.high.rawValue
        let (last, before) = (TrackID("t20"), TrackID("t19"))

        model.armed = [last]
        await studio.perform(.seek(.frame(100_000)))
        await until(limit: .seconds(10), "the warning of t20 shows") {
            model.shown.recordOver.reached.map(\.track) == [last]
        }
        #expect(heard.lines == ["\(high) \(model.shown.recordOver.detail)"], "a new key is announced at high priority")

        await studio.perform(.seek(.frame(120_000)))
        chrome.update()
        #expect(heard.lines.count == 1, "the same key in the same clip is not announced again")

        model.armed = []
        await until(limit: .seconds(10), "the warning goes") { model.shown.recordOver.isEmpty }
        model.armed = [last]
        await until(limit: .seconds(10), "the warning of t20 is back") { !model.shown.recordOver.isEmpty }
        #expect(heard.lines.count == 1, "an empty key keeps the last key, so the same warning is not new")

        let visible = try #require(model.timeline.visible)
        try #require(!visible.lanes.contains(18), "t19 is out of view: \(visible)")
        model.armed = [before, last]
        await until(limit: .seconds(10), "the warning has both tracks") {
            model.shown.recordOver.reached.map(\.track) == [before, last]
        }
        #expect(heard.lines.count == 2, "two hidden tracks are a new key")
        #expect(heard.lines.last == "\(high) \(model.shown.recordOver.detail)")
        await model.close()
    }

    /// C5: a play from one clip over its end on a lane out of view changes the first
    /// reached clip of the warning, but not its key, so it announces nothing.
    @Test func playAcrossAClipEndOnAHiddenLaneAnnouncesNothingNew() async throws {
        let (model, studio, chrome, _, heard) = try await warningWindow()
        try studio.edit(ripple: false) { s throws(SessionError) in _ = try s.splitClips(at: [200_000], on: ["t20"]) }
        model.armed = ["t20"]
        await studio.perform(.seek(.frame(190_000)))
        await until(limit: .seconds(10), "the warning reaches the first clip") {
            model.shown.recordOver.reached.map(\.clip) == ["c20"]
        }
        #expect(heard.lines.count == 1)

        await studio.perform(.playStop)
        _ = await studio.renderOffline(frames: 48_000)
        chrome.update()
        await until(limit: .seconds(10), "the warning reaches the second clip") {
            chrome.update()
            return model.shown.recordOver.reached.map(\.clip).first.map { $0 != "c20" } ?? false
        }

        #expect(heard.lines.count == 1, "the clip changed and the key did not: \(heard.lines)")
        await studio.perform(.playStop)
        await model.close()
    }

    /// C5: with t1 and t20 armed, the hidden track decides the key. The top gives [t20], the bottom
    /// [t1], and the top again [t20], which differs from the last announced key [t1].
    @Test func aVerticalScrollWithTwoArmedTracksAnnouncesEachNewKey() async throws {
        let (model, studio, _, view, heard) = try await warningWindow()
        let (first, last) = (TrackID("t1"), TrackID("t\(TimelineViewTests.tracksThatDoNotFit)"))
        func scroll(toBottom: Bool) {
            let clip = view.contentView
            let insets = clip.contentInsets
            let bottom = (view.documentView?.frame.height ?? 0) - clip.bounds.height + insets.bottom
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: toBottom ? bottom : -insets.top))
            view.reflectScrolledClipView(clip)
        }
        scroll(toBottom: false)
        model.armed = [first, last]
        await studio.perform(.seek(.frame(100_000)))
        await until(limit: .seconds(10), "the warning names t20") {
            model.shown.recordOver.reached.map(\.track) == [last]
        }
        try #require(model.timeline.visible?.lanes.contains(0) == true)
        #expect(heard.lines.count == 1, "the top gives [t20]")

        scroll(toBottom: true)
        await until(limit: .seconds(10), "the warning names t1") {
            model.shown.recordOver.reached.map(\.track) == [first]
        }
        try #require(model.timeline.visible?.lanes.contains(0) == false)
        #expect(heard.lines.count == 2, "the bottom gives [t1]")

        scroll(toBottom: false)
        await until(limit: .seconds(10), "the warning names t20 again") {
            model.shown.recordOver.reached.map(\.track) == [last]
        }
        #expect(heard.lines.count == 3, "the top again gives [t20], which differs from [t1]")
        await model.close()
    }
}
