import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The pane and its text are freed with the tab and the window, and the pane follows the display
/// options (run transcript-1, landing 2, criteria P4, P4b).
extension TranscriptPaneTests {
    /// A weak reference to a pane, so a test holds nothing that keeps it alive.
    @MainActor final class WeakPane {
        weak var pane: TranscriptTextView?
        init(_ pane: TranscriptTextView) { self.pane = pane }
    }

    /// Opens a session at the Transcript tab and returns the window model with no strong reference
    /// to the window, the lanes, or the pane.
    func showingPane(name: String) async throws -> (SessionWindow, WeakPane) {
        let (model, _, window, view) = try await open(try await package(name: name))
        model.showTranscript()
        let weak = WeakPane(try await waitForPane(window))
        #expect(window.makeFirstResponder(view.lanes), "the focus leaves the pane")
        return (model, weak)
    }

    /// P4: a tab change removes the pane, and the window model holds the pane only weakly. A window
    /// close frees the pane that shows. The text storage of a TextKit 2 view stays alive after the
    /// view is freed (AppKit), so the test does not assert it.
    @Test func paneIsFreedAfterATabChangeAndWindowClose() async throws {
        let (model, first) = try await showingPane(name: "freed")
        #expect(first.pane != nil && model.transcriptFollow.pane === first.pane, "the pane shows")
        model.selectInspectorTab(.clip)
        await until("the tab change frees the pane") { first.pane == nil }
        #expect(model.transcriptFollow.pane == nil)

        model.showTranscript()
        await until("a new pane shows") { model.transcriptFollow.pane != nil }
        let second = try #require(model.transcriptFollow.pane.map(WeakPane.init))
        #expect(second.pane !== first.pane)
        await model.close()
        await until("the window close frees the pane") { second.pane == nil }
    }

    /// P4: the underline takes the width of Increase Contrast and the color of the playhead again
    /// when the display options or the system colors change while the pane shows.
    @Test func displayOptionNotificationsStyleTheUnderline() async throws {
        let (model, _, window, _) = try await open(try await package(name: "notes"))
        model.showTranscript()
        let pane = try await waitForPane(window)
        let unit = try secondUnit(pane)
        pane.appearance = NSAppearance(named: .aqua)
        model.transcriptTick(frame: Self.second)
        let segments = try segments(of: unit.text, in: pane)
        #expect(!segments.isEmpty && pane.underlines.count == segments.count)

        let system = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        pane.increaseContrast = !system
        #expect(pane.underlines.map(\.frame) == segments.map { underline($0, width: system ? 2 : 3) })
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(pane.increaseContrast == system, "the notification reads the system setting")
        #expect(pane.underlines.map(\.frame) == segments.map { underline($0, width: system ? 3 : 2) })

        let ink = CGColor(srgbRed: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 1)
        for layer in pane.underlines { layer.backgroundColor = CGColor(gray: 0.5, alpha: 1) }
        NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
        #expect(pane.underlines.allSatisfy { $0.backgroundColor == ink }, "the system colors set the color again")
        await model.close()
    }
}
