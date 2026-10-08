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
/// states of a test process (BannerTests, A14).
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
}
