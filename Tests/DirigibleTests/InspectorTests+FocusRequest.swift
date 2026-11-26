import AppKit
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleTimeline

/// The focus request of the inspector panes (run 2026-11-26-inspector-focus-request, item 1953):
/// a request stays until the field is first responder, and it ends there.
extension InspectorTests {
    /// Runs `count` layout passes of the window, each followed by a main-actor turn, so SwiftUI
    /// reports a focus move and the pane answers it. A pass is no wall-clock wait.
    func settle(_ window: NSWindow, passes count: Int = 20) async {
        for _ in 0..<count {
            window.contentView?.layoutSubtreeIfNeeded()
            await Task.yield()
        }
    }

    /// Item 1953: a request that comes while the pane shows No Marker stays when the marker, and so
    /// the fields, appear later. Name then gets the focus.
    @Test func markerInfoKeepsItsFocusRequestUntilTheFieldsAppear() async throws {
        let (model, _, window, _) = try await open(try await package())
        model.timeline.marker = "c1"
        model.selectInspectorTab(.marker)
        model.markerFocusRequest = .name
        await settle(window)
        #expect(shownFields(window).isEmpty, "No Marker: no fields")
        #expect(model.markerFocusRequest == .name, "the request \(String(describing: model.markerFocusRequest))")

        addMarkers(model)
        try await waitForNameFocus(model, window, "One")
        await model.close()
    }

    /// Item 1953: a request ends when Name has the focus. A click away after that leaves the
    /// lanes as first responder.
    @Test func aClickAwayAfterMarkerInfoKeepsTheLanes() async throws {
        let (model, _, window, view) = try await open(try await package())
        addMarkers(model)
        model.timeline.marker = "c1"
        model.run(.markerInfo)
        try await waitForNameFocus(model, window, "One")
        await until(limit: .seconds(10), "the request ends") { model.markerFocusRequest == nil }

        #expect(window.makeFirstResponder(view.lanes))
        await settle(window)
        #expect(
            model.markerFocus == nil && window.firstResponder === view.lanes,
            "focus \(String(describing: model.markerFocus)), responder \(String(describing: window.firstResponder))")
        await model.close()
    }
}
