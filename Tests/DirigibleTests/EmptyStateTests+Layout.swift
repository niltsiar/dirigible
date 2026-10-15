import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The place and the form of the empty state beside the inspector (run ui-polish-chrome
/// criteria C1 to C6). The test process shows the string keys.
extension EmptyStateTests {
    /// An empty session at a content width of 1180 pt, with the inspector at `inspector` pt or
    /// hidden (nil), and the result banner above the empty state when `banner` is true.
    func emptyWindow(_ name: String, inspector: Double?, banner: Bool = false) async throws
        -> (SessionWindow, NSWindow)
    {
        let url = folder.url.appending(path: "\(name).dirigible")
        try await Task.detached { try Session.create(at: url, sampleRate: 48_000) }.value
        let model = await app.open(url)
        let studio = try #require(await model.opened() ? model.studio : nil)
        try await fixFreeSpace(model)
        let window = try #require(model.window)
        if let inspector { model.inspectorWidth = InspectorWidth(inspector) }
        if (inspector != nil) != model.showsInspector { model.toggleInspector() }
        if banner { studio.lastTake = TakeResult(take: 1, end: .diskLow, gaps: [:]) }
        window.setContentSize(NSSize(width: 1180, height: 560))
        await until("the window takes 1180 pt") {
            window.contentView?.layoutSubtreeIfNeeded()
            return window.contentLayoutRect.width == 1180
        }
        return (model, window)
    }

    /// The alignment rect of `view` in window coordinates.
    func frame(_ view: NSView) -> NSRect { view.convert(view.alignmentRect(forFrame: view.bounds), to: nil) }

    /// The Add Track button and the Add Call Tracks menu, once they show.
    func actions(_ window: NSWindow) async throws -> (add: NSButton, call: NSPopUpButton) {
        var found: (NSButton, NSPopUpButton)?
        await until(limit: .seconds(10), "the empty state shows its actions") {
            window.contentView?.layoutSubtreeIfNeeded()
            let buttons = views(NSButton.self, under: window.contentView).filter { !($0 is NSPopUpButton) }
            let menus = views(NSPopUpButton.self, under: window.contentView)
            guard buttons.count == 1, menus.count == 1 else { return false }
            found = (buttons[0], menus[0])
            return true
        }
        let (add, call) = try #require(found)
        return (add, call)
    }

    /// C1, C2, C3: Add Track is at the middle of the area beside the inspector, with and without
    /// the result banner; the handle is on the inspector edge.
    @Test func theEmptyStateCentersBesideTheInspector() async throws {
        let cases: [(inspector: Double?, banner: Bool)] = [
            (270, false), (270, true), (nil, false), (nil, true), (400, false), (400, true),
        ]
        for (n, (inspector, banner)) in cases.enumerated() {
            let (model, window) = try await emptyWindow("c\(n)", inspector: inspector, banner: banner)
            let (add, _) = try await actions(window)
            let free = 1180 - (inspector ?? 0)
            let midX = Double(frame(add).midX)
            #expect(abs(midX - free / 2) <= 2, "inspector \(String(describing: inspector)), banner \(banner): \(midX)")
            if inspector != nil {
                let handle = try #require(
                    views(InspectorHandleView.self, under: window.contentView).first, "no inspector handle")
                #expect(abs(Double(frame(handle).midX) - free) <= 1, "handle \(frame(handle))")
            }
            await model.close()
        }
    }

    /// C5: the two actions are one stack: one width, one height under 28 pt, one `minX`, and Add
    /// Track above Add Call Tracks.
    @Test func theEmptyActionsAreOneStack() async throws {
        let (model, window) = try await emptyWindow("stack", inspector: 270)
        let (add, call) = try await actions(window)
        let (a, c) = (frame(add), frame(call))
        #expect(abs(a.width - c.width) <= 0.5, "widths \(a.width) and \(c.width)")
        #expect(abs(a.height - c.height) <= 0.5 && a.height < 28, "heights \(a.height) and \(c.height)")
        #expect(abs(a.minX - c.minX) <= 0.5, "minX \(a.minX) and \(c.minX)")
        #expect(a.minY > c.maxY, "Add Track \(a) is not above Add Call Tracks \(c)")
        await model.close()
    }
}
