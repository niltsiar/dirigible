import AppKit
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleTimeline

/// The focus request of the inspector panes (item 1953): a request stays until the field is first
/// responder, and it ends there.
extension InspectorTests {
    /// Runs 20 layout passes of the window, each followed by a main-actor turn, so SwiftUI
    /// reports a focus move and the pane answers it. A pass is no wall-clock wait.
    func settle(_ window: NSWindow) async {
        for _ in 0..<20 {
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

    /// Item 1953: a request ends when Title has the focus. A click away after that leaves the
    /// lanes as first responder.
    @Test func aClickAwayAfterEpisodeInfoKeepsTheLanes() async throws {
        let (model, _, window, view) = try await open(try await package())
        model.showEpisodeInfo()
        try await waitForTitleFocus(model, window)
        await until(limit: .seconds(10), "the request ends") { model.episodeFocusRequest == nil }

        #expect(window.makeFirstResponder(view.lanes))
        await settle(window)
        #expect(
            model.episodeFocus == nil && window.firstResponder === view.lanes,
            "focus \(String(describing: model.episodeFocus)), responder \(String(describing: window.firstResponder))")
        await model.close()
    }
}
