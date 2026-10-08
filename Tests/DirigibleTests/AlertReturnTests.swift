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
        // A diagnostic for a red run: the title and the key of each button.
        print("app-bug-batch \(alert): \(buttons(sheet.contentView).map { ($0.title, $0.keyEquivalent) })")
        return (model, window, sheet)
    }

    /// The error alert (also of a failed import) and the Exported alert. OK has only Return: SwiftUI
    /// gives no form with both keys (logs/s2-u3-probe.log), as the NSAlert of a failed Create.
    @Test(arguments: [true, false]) func okTakesReturn(error: Bool) async throws {
        let (model, window, sheet) = try await show(
            error ? .error(.audioImport(.notAudio(file: "notes.mp3"))) : .exported(["a.wav"], nil))

        try press("\r", code: 36, in: sheet)

        await until("Return closes the alert") { model.alert == nil && window.attachedSheet == nil }
        await model.close()
    }

    @Test func stopAndCloseTakesReturn() async throws {
        let (model, _, sheet) = try await show(.confirmStopAndClose)
        let cancel = buttons(sheet.contentView).first { $0.keyEquivalent == "\u{1b}" }
        #expect(cancel?.title == L10n.alertCancel.text, "Esc gives Cancel")

        try press("\r", code: 36, in: sheet)

        await until("Return answers Stop and Close") { model.alert == nil && app.windows.isEmpty }
    }

    @Test func unsavedCloseRefusesReturn() async throws {
        let (model, window, sheet) = try await show(.confirmUnsavedClose)

        try press("\r", code: 36, in: sheet)
        // Esc then proves that the keys reach the sheet: it answers Cancel after the Return.
        #expect(model.alert == .confirmUnsavedClose && window.isVisible, "Return keeps the question")
        try press("\u{1b}", code: 53, in: sheet)

        await until("Esc answers Cancel") { model.alert == nil && window.attachedSheet == nil }
        #expect(window.isVisible && app.windows.count == 1, "Cancel keeps the window")
        await model.close()
    }

    func buttons(_ view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }

    /// A key-down with no modifier to the sheet, as the window server gives it (ExportWindowTests).
    func press(_ key: String, code: UInt16, in sheet: NSWindow) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: sheet.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
        if !sheet.performKeyEquivalent(with: event) { sheet.sendEvent(event) }
    }
}
