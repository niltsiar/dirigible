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
        #expect(model.inspectorResize.preview?.points == 325, "the guide moves from the shown width")
        model.dragInspector(.drag(x: -5))
        #expect(model.inspectorResize.preview?.points == 320, "the guide stops at the tab minimum")
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

    /// One rule for the drag and the step: a request at or under 320 pt saves the lower of the
    /// saved width and 320; a request above 320 pt saves the request.
    @Test func dragThatNarrowsAWideSavedWidthSavesTheMinimum() async throws {
        let (model, _) = try await wideTranscriptTab(saved: 400)
        model.dragInspector(.down(x: 0, clicks: 1))
        model.dragInspector(.drag(x: -150))
        #expect(model.inspectorResize.preview?.points == 320)
        model.dragInspector(.up)
        #expect(model.inspectorWidth.points == 320, "a drag to 250 saves 320")
        #expect(defaults.object(forKey: InspectorWidth.defaultsKey) as? Double == 320)
        await model.close()
    }

    @Test func dragThatNarrowsANarrowSavedWidthKeepsIt() async throws {
        let (model, _) = try await wideTranscriptTab(saved: 240)
        model.dragInspector(.down(x: 0, clicks: 1))
        model.dragInspector(.drag(x: -70))
        model.dragInspector(.up)
        #expect(model.inspectorWidth.points == 240, "a drag to 250 keeps 240")
        #expect(defaults.object(forKey: InspectorWidth.defaultsKey) == nil)
        await model.close()
    }

    /// The step uses the rule of the drag: from the shown width, saved by the same function.
    @Test func stepOnTheTranscriptTabFollowsTheWidthRule() async throws {
        let (model, _) = try await wideTranscriptTab(saved: 400)
        for (saved, step, expected) in [(400.0, -20.0, 380.0), (330, -20, 320), (240, -20, 240), (240, 20, 340)] {
            model.inspectorWidth = InspectorWidth(saved)
            model.stepInspector(by: step)
            #expect(model.inspectorWidth.points == expected, "saved \(saved), step \(step)")
        }
        await model.close()
    }
}
