import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run app-bug-batch C1 and C2: the real Return key on the alert sheet of a session window. The
/// error, Exported, and Stop and Close alerts take Return (HIG: Cancel is never the default). The
/// unsaved-close question does not: one Return would drop edits that Undo cannot give back.
@Suite(.serialized) @MainActor struct AlertReturnTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    /// A key window with one track, and its alert sheet for `alert`.
    func show(_ alert: WindowAlert) async throws -> (SessionWindow, NSWindow, NSWindow) {
        let package = try await timelinePackage(in: folder.url, tracks: 1, seconds: 1)
        let (model, _, window, _) = try await openLanes(app, package)
        model.alert = alert
        await until("the alert sheet shows") { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        sheet.contentView?.layoutSubtreeIfNeeded()
        return (model, window, sheet)
    }

    /// The error alert (also of a failed import) and the Exported alert. OK has only Return: SwiftUI
    /// gives no form with both keys (logs/s2-u3-probe.log), as the NSAlert of a failed Create.
    @Test(arguments: [true, false]) func okTakesReturn(error: Bool) async throws {
        let (model, window, sheet) = try await show(
            error ? .error(.audioImport(.notAudio(file: "notes.mp3"))) : .exported(["a.wav"], nil))

        press("\r", code: 36, in: sheet)

        await until("Return closes the alert") { model.alert == nil && window.attachedSheet == nil }
        await model.close()
    }

    /// The overlap alert of Follow in Ripples on a window where track `t1` follows.
    func showFollowOverlap() async throws -> (SessionWindow, NSWindow, NSWindow) {
        let overlap = FollowOverlap(track: "t1", trackName: "T1", start: 48_000, rate: 48_000)
        let shown = try await show(.followOverlap(overlap))
        let studio = try #require(shown.0.studio)
        try studio.edit(ripple: false) { s throws(SessionError) in try s.setFollowTrack(true, tracks: ["t1"]) }
        return shown
    }

    /// ui-audit A4: the overlap alert of Follow in Ripples names its two actions, with no OK. Return
    /// answers Keep On, so it closes the alert and Follow stays on.
    @Test func returnOnTheFollowOverlapAlertKeepsFollowOn() async throws {
        let (model, window, sheet) = try await showFollowOverlap()
        #expect(
            buttons(sheet.contentView).map(\.title).sorted()
                == [L10n.alertFollowKeepOn.text, L10n.alertFollowTurnOff.text].sorted())
        let defaultButton = buttons(sheet.contentView).first { $0.keyEquivalent == "\r" }
        #expect(defaultButton?.title == L10n.alertFollowKeepOn.text)

        press("\r", code: 36, in: sheet)

        await until("Return closes the alert") { model.alert == nil && window.attachedSheet == nil }
        #expect(model.follows(["t1"]), "Return keeps Follow on")
        await model.close()
    }

    @Test func turnOffOnTheFollowOverlapAlertTurnsFollowOff() async throws {
        let (model, window, sheet) = try await showFollowOverlap()
        #expect(model.follows(["t1"]))

        let turnOff = try #require(buttons(sheet.contentView).first { $0.title == L10n.alertFollowTurnOff.text })
        turnOff.performClick(nil)

        await until("Turn Off closes the alert") { model.alert == nil && window.attachedSheet == nil }
        #expect(!model.follows(["t1"]), "Turn Off ends Follow")
        await model.close()
    }

    @Test func stopAndCloseTakesReturn() async throws {
        let (model, _, sheet) = try await show(.confirmStopAndClose)
        let cancel = buttons(sheet.contentView).first { $0.keyEquivalent == "\u{1b}" }
        #expect(cancel?.title == L10n.alertCancel.text, "Esc gives Cancel")

        press("\r", code: 36, in: sheet)

        await until("Return answers Stop and Close") { model.alert == nil && app.windows.isEmpty }
    }

    @Test func unsavedCloseRefusesReturn() async throws {
        let (model, window, sheet) = try await show(.confirmUnsavedClose)

        press("\r", code: 36, in: sheet)
        // Esc then proves that the keys reach the sheet: it answers Cancel after the Return.
        #expect(model.alert == .confirmUnsavedClose && window.isVisible, "Return keeps the question")
        press("\u{1b}", code: 53, in: sheet)

        await until("Esc answers Cancel") { model.alert == nil && window.attachedSheet == nil }
        #expect(window.isVisible && app.windows.count == 1, "Cancel keeps the window")
        await model.close()
    }

    /// Decision 0014: Stop and Quit takes Return, as Stop and Close. After a failed save, Quit takes
    /// no Return, as the unsaved Close. Cancel has Esc in each language: NSAlert gives Esc only to a
    /// button titled "Cancel". The real keys are an on-screen check (`runModal` blocks a test).
    @Test(arguments: [false, true]) func quitQuestionKeys(unsaved: Bool) {
        let alert = quitQuestion("Quit?", button: "Quit", unsaved: unsaved)

        #expect(alert.buttons.map(\.keyEquivalent) == [unsaved ? "" : "\r", "\u{1b}"])
    }

    func buttons(_ view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }

    /// A key-down with no modifier to the sheet, as the window server gives it (ExportWindowTests).
    func press(_ characters: String, code: UInt16, in sheet: NSWindow) {
        let event = key(.keyDown, characters, code: code, in: sheet)
        if !sheet.performKeyEquivalent(with: event) { sheet.sendEvent(event) }
    }
}
