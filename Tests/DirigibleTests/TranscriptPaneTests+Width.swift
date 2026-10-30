import AppKit
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// The inspector handle on the Transcript tab: the tab minimum of 320 pt never changes the saved
/// width (code gate 3, items 3 and 4).
extension TranscriptPaneTests {
    private func wideTranscriptTab(saved: Double) async throws -> (SessionWindow, NSWindow) {
        let (model, _, window, _) = try await open(try await package())
        window.setContentSize(NSSize(width: 1400, height: 600))
        await until("the window takes 1400 pt") { window.contentLayoutRect.width == 1400 }
        model.inspectorWidth = InspectorWidth(saved)
        model.selectInspectorTab(.transcript)
        return (model, window)
    }

    /// A drag starts at the shown width, so the guide follows the pointer from the first point. A
    /// drag to or under 320 pt and Esc save nothing and leave the saved 240; a drag above 320 saves.
    @Test func dragOnTheTranscriptTabKeepsTheSavedWidth() async throws {
        let (model, _) = try await wideTranscriptTab(saved: 240)
        #expect(model.shownInspectorWidth == 320)

        model.dragInspector(.down(x: 0, clicks: 1))
        model.dragInspector(.drag(x: 5))
        #expect(model.inspectorPreview?.points == 325, "the guide moves from the shown width")
        model.dragInspector(.drag(x: -5))
        #expect(model.inspectorPreview?.points == 320, "the guide stops at the tab minimum")
        model.dragInspector(.up)
        #expect(model.inspectorWidth.points == 240, "a drag under 320 keeps the saved width")
        #expect(defaults.object(forKey: InspectorWidth.defaultsKey) == nil, "and saves nothing")

        model.dragInspector(.down(x: 0, clicks: 1))
        model.dragInspector(.drag(x: 40))
        #expect(model.cancelInspectorDrag())
        #expect(model.inspectorWidth.points == 240, "Esc keeps the saved width")
        #expect(defaults.object(forKey: InspectorWidth.defaultsKey) == nil)

        model.dragInspector(.down(x: 0, clicks: 1))
        model.dragInspector(.drag(x: 40))
        model.dragInspector(.up)
        #expect(model.inspectorWidth.points == 360, "a drag above 320 sets the width")
        #expect(defaults.object(forKey: InspectorWidth.defaultsKey) as? Double == 360)
        await model.close()
    }

    /// A wide saved width that a drag narrows below the tab minimum ends at the minimum.
    @Test func dragBelowTheMinimumNarrowsAWideSavedWidth() async throws {
        let (model, _) = try await wideTranscriptTab(saved: 400)
        model.dragInspector(.down(x: 0, clicks: 1))
        model.dragInspector(.drag(x: -100))
        model.dragInspector(.up)
        #expect(model.inspectorWidth.points == 320)
        #expect(defaults.object(forKey: InspectorWidth.defaultsKey) as? Double == 320)
        await model.close()
    }

    /// A step moves the saved width in its direction: down from the saved width, up from the shown one.
    @Test func stepOnTheTranscriptTabMovesTheSavedWidthWithItsDirection() async throws {
        let (model, _) = try await wideTranscriptTab(saved: 300)
        model.stepInspector(by: -20)
        #expect(model.inspectorWidth.points == 280, "a decrement lowers the saved width")
        model.stepInspector(by: 20)
        #expect(model.inspectorWidth.points == 340, "an increment starts at the shown 320")
        await model.close()
    }
}
