import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 1b criterion H4: the header width is an app preference under `timeline.header.width`. It
/// saves at the mouse-up, the double-click, and an AX step, and each new session window reads it
/// at open. Each test has its own defaults domain and removes it at the end; no test writes
/// `UserDefaults.standard`.
@Suite(.serialized) @MainActor struct HeaderWidthSaveTests {
    let folder: TemporaryFolder
    let domain = "dirigible.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let app: AppDelegate

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
        defaults = try #require(UserDefaults(suiteName: domain))
        app = AppDelegate(recordings: nil, defaults: defaults)
    }

    func end(_ models: SessionWindow...) async {
        for model in models { await model.close() }
        defaults.removePersistentDomain(forName: domain)
    }

    var stored: Any? { defaults.object(forKey: HeaderWidth.defaultsKey) }

    func open(_ name: String = "a") async throws -> (SessionWindow, TimelineScrollView) {
        let folder = self.folder.url.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (model, _, _, view) = try await openLanes(
            app, try await timelinePackage(in: folder, tracks: 2, seconds: 20))
        return (model, view)
    }

    func handle(_ type: NSEvent.EventType, _ x: Double, _ view: TimelineScrollView, clicks: Int = 1) throws {
        let window = try #require(view.window)
        let location = view.headers.convert(NSPoint(x: x, y: view.headers.bounds.midY), to: nil)
        let event = try #require(
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
        switch type {
        case .leftMouseDown:
            drawNow(window)
            try #require(window.contentView?.superview?.hitTest(location) === view.headers.handle, "the handle at \(x)")
            view.headers.handle.mouseDown(with: event)
        case .leftMouseDragged: view.headers.handle.mouseDragged(with: event)
        default: view.headers.handle.mouseUp(with: event)
        }
    }

    @Test func theWidthSavesAtTheMouseUpOnly() async throws {
        let (model, view) = try await open()
        try handle(.leftMouseDown, 337, view)
        try handle(.leftMouseDragged, 417, view)
        #expect(stored == nil, "not saved during the drag")
        try handle(.leftMouseUp, 417, view)
        #expect(stored as? Double == 420, "saved at the up")

        defaults.removeObject(forKey: HeaderWidth.defaultsKey)
        try handle(.leftMouseDown, 417, view)
        try handle(.leftMouseDragged, 377, view)
        try #require(view.headers.width == HeaderWidth(380))
        try #require(view.window).sendEvent(try cgKey(53))
        try handle(.leftMouseUp, 377, view)
        #expect(stored == nil, "not saved at Esc")
        try handle(.leftMouseDown, 417, view)
        try handle(.leftMouseUp, 417, view)
        #expect(stored == nil, "not saved at a click")

        try handle(.leftMouseDown, 417, view, clicks: 2)
        try handle(.leftMouseUp, 417, view, clicks: 2)
        #expect(stored as? Double == 340, "saved at a double-click")
        _ = view.headers.handle.accessibilityPerformIncrement()
        #expect(stored as? Double == 360, "saved at an AX step")
        await end(model)
    }

    @Test func aNewWindowReadsTheSavedWidth() async throws {
        defaults.set(260.0, forKey: HeaderWidth.defaultsKey)
        let (model, view) = try await open()
        #expect(view.headers.ruleThickness == 260, "read at open")
        await end(model)
    }

    /// A value that another app version or `defaults write` stored.
    enum Stored: Sendable {
        case text(String)
        case number(Double)
        case integer(Int)
        var value: Any {
            switch self {
            case .text(let text): text
            case .number(let number): number
            case .integer(let integer): integer
            }
        }
    }

    @Test(arguments: [
        (Stored.text("abc"), 340.0), (.number(9999), 480), (.number(-5), 180), (.integer(300), 300),
    ])
    func aBadStoredWidthGivesAWidthInRange(value: Stored, width: Double) async throws {
        defaults.set(value.value, forKey: HeaderWidth.defaultsKey)
        let (model, view) = try await open()
        #expect(Double(view.headers.ruleThickness) == width, "stored value \(value) gives \(width)")
        await end(model)
    }

    /// Decision 0023: the width of one window does not change the other open windows until their
    /// next open; a window opened after the drag has the saved width.
    @Test func aDragInOneWindowLeavesTheOtherWindow() async throws {
        let (first, one) = try await open("a")
        let (second, two) = try await open("b")
        try handle(.leftMouseDown, 337, one)
        try handle(.leftMouseDragged, 417, one)
        try handle(.leftMouseUp, 417, one)
        #expect(one.headers.width == HeaderWidth(420))
        #expect(two.headers.width == .standard, "the other window keeps its width")
        let (third, three) = try await open("c")
        #expect(three.headers.ruleThickness == 420, "read at open: a new window has the saved width")
        await end(first, second, third)
    }
}
