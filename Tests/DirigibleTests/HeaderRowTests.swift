import AppKit
import DirigibleCore
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 1b criteria H6 and H7: the header rows show one line under 56 pt, the name is 13 pt, the
/// name field and the route menu flex with the header width, and each row has a separator at the
/// lane edge. The rows are AppKit views under the hosting view (probe Q2), so the tests read the
/// frames of the SwiftUI hosts of the controls.
@Suite(.serialized) @MainActor struct HeaderRowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
    }

    /// The model of a 2-track package.
    func model() async throws -> (SessionWindow, Studio) {
        try await timelineModel(try await timelinePackage(in: folder.url, tracks: 2, seconds: 1), app: app)
    }

    /// The rows in a hosting view of the header `width`, as the header ruler hosts them.
    func rows(_ model: SessionWindow, _ studio: Studio, laneHeight: Double, width: Double) -> (NSWindow, NSView) {
        let size = NSSize(width: width, height: laneHeight * 2)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: TrackHeaders(model: model, studio: studio, laneHeight: laneHeight))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        drawNow(window)
        return (window, host)
    }

    /// The SwiftUI hosts of the AppKit controls under `view`, in the coordinates of `root`.
    func controls(_ view: NSView, in root: NSView) -> [(kind: String, frame: NSRect, view: NSView)] {
        let name = String(describing: type(of: view))
        var found: [(String, NSRect, NSView)] = []
        if name.hasPrefix("PlatformViewHost") {
            let kind =
                name.contains("Checkbox")
                ? "arm" : name.contains("TextField") ? "name" : name.contains("Progress") ? "meter" : "route"
            found.append((kind, view.convert(view.bounds, to: root), view))
        }
        return found + view.subviews.flatMap { controls($0, in: root) }
    }

    @Test func aRowUnder56PointsShowsOneLine() async throws {
        let (model, studio) = try await model()
        // The route control is on the line of the name at 55 pt and under it at 56 pt.
        func routeUnderName(_ host: NSView) -> [Bool] {
            let found = controls(host, in: host)
            let names = found.filter { $0.kind == "name" }.map(\.frame)
            let routes = found.filter { $0.kind == "route" }.map(\.frame)
            return zip(names, routes).map { $1.midY > $0.maxY }
        }
        let (short, low) = rows(model, studio, laneHeight: 55, width: 340)
        #expect(routeUnderName(low) == [false, false], "one line at 55")
        let (tall, high) = rows(model, studio, laneHeight: 56, width: 340)
        #expect(routeUnderName(high) == [true, true], "two lines at 56")
        short.close()
        tall.close()
        await model.close()
    }

    /// Code gate 1 item 4: a lane under 56 pt still shows a route control and the live state of a
    /// take on its one line: a red state symbol for a lost device (a capture of the rows: the
    /// symbol is SwiftUI drawing), and no red in a row with no state.
    @Test func aOneLineRowShowsTheRouteAndTheState() async throws {
        let (model, studio) = try await model()
        studio.liveTracks["t1"] = LiveTrack(state: .deviceLost, droppedFrames: 0, peak: 0)
        for width in [180.0, 340] {
            let (window, host) = rows(model, studio, laneHeight: 50, width: width)
            let found = controls(host, in: host)
            #expect(found.filter { $0.kind == "route" }.count == 2, "a route control in each row at \(width)")
            for control in found {
                #expect(
                    control.frame.minX >= 8 && control.frame.maxX <= width - 8,
                    "inside the one-line row at \(width): \(control.kind) \(control.frame)")
            }
            // A capture of the window: a snapshot does not draw the SwiftUI symbol.
            window.orderFront(nil)
            drawNow(window)
            try await Task.sleep(for: .milliseconds(200))
            let capture = try TimelineColorTests.capture(window)
            func red(_ lane: Int) throws -> Int {
                let rect = host.convert(NSRect(x: 0, y: Double(lane) * 50, width: width, height: 50), to: nil)
                return try TimelineRulerTests.pixels(of: rect, capture, window).filter { pixel in
                    let (r, g, b) = (pixel >> 16 & 0xFF, pixel >> 8 & 0xFF, pixel & 0xFF)
                    return r > 180 && g < 90 && b < 90
                }.count
            }
            #expect(try red(0) > 10, "the state symbol shows in the row of the lost device at \(width)")
            #expect(try red(1) == 0, "no state symbol in a row with no state at \(width)")
            window.close()
        }
        await model.close()
    }

    @Test func theNameIs13Points() async throws {
        let (model, studio) = try await model()
        let (window, host) = rows(model, studio, laneHeight: 100, width: 340)
        let names = controls(host, in: host).filter { $0.kind == "name" }
        let fields = names.compactMap { $0.view.subviews.first as? NSTextField }
        #expect(fields.count == 2 && fields.allSatisfy { $0.font?.pointSize == 13 }, "name font: \(fields.map(\.font))")
        window.close()
        await model.close()
    }

    @Test func theNameAndRouteFlexWithTheHeaderWidth() async throws {
        let (model, studio) = try await model()
        var names: [Double: Double] = [:]
        for width in [180.0, 340, 480] {
            let (window, host) = rows(model, studio, laneHeight: 100, width: width)
            let found = controls(host, in: host)
            #expect(found.count == 6, "\(width): arm, name, and route in each row")
            for control in found {
                #expect(
                    control.frame.minX >= 8 && control.frame.maxX <= width - 8,
                    "inside the row at \(width): \(control.kind) \(control.frame)")
            }
            // The route label of a long device name is not in this process: `L10n` gives the key
            // of the route text, not the name. Phase 7 checks the cut on a screenshot (M3h).
            names[width] = found.first { $0.kind == "name" }.map { Double($0.frame.width) }
            window.close()
        }
        let (n180, n340, n480) = (names[180] ?? 0, names[340] ?? 0, names[480] ?? 0)
        #expect(abs(n480 - n340 - 140) <= 1, "the name grows: \(n340) to \(n480)")
        #expect(n180 >= 60, "the name minimum: \(n180)")
        await model.close()
    }

    /// Code gate 1 item 1: the row layout comes from the header width and the lane height, not from
    /// the text. A long typed name keeps the same field and its focus, and commits nothing.
    @Test func aLongTypedNameKeepsTheFieldAndTheFocus() async throws {
        let (model, studio, window, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 20))
        let editor = try await focusName(in: window)
        let field = try #require(editor.delegate as? NSTextField)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        let draft = String(repeating: "Long name ", count: 4)
        // One insert and one layout pass: a longer test gave the key status of the test process
        // to the window of another suite, and a field with no focus commits its name.
        editor.insertText(draft, replacementRange: editor.selectedRange())
        window.contentView?.layoutSubtreeIfNeeded()
        drawNow(window)
        try #require(model.drafts["t1"] == "T1" + draft, "the typed name is a draft")
        #expect(field.window === window && window.firstResponder === editor, "the same field keeps the focus")
        #expect(editor.delegate === field, "the same field keeps the focus: the editor")
        #expect(
            studio.session.track("t1")?.name == "T1",
            "no rename before Return: \(studio.session.track("t1")?.name ?? "")")
        await model.close()
    }

    /// A 1 pt separator at the bottom of each row: at x 4 pt in the header column, the pixel row
    /// at the bottom point of a row is darker than the pixel 4 pt above it.
    @Test func eachRowHasASeparatorAtTheLaneEdge() async throws {
        let (model, _, window, view) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 20))
        window.appearance = NSAppearance(named: .aqua)
        drawNow(window)
        try await Task.sleep(for: .milliseconds(200))
        let capture = try TimelineColorTests.capture(window)
        let laneHeight = try #require(view.lanes.inputs?.laneHeight)
        let x = view.headers.convert(NSPoint(x: 4, y: 0), to: nil).x
        for lane in 1...2 {
            let bottom = view.lanes.convert(NSPoint(x: 0, y: Double(lane) * laneHeight - 0.5), to: nil).y
            let edge = try TimelineRulerTests.pixels(
                of: NSRect(x: x, y: bottom, width: 0.5, height: 0.5), capture, window)
            let above = try TimelineRulerTests.pixels(
                of: NSRect(x: x, y: bottom + 4, width: 0.5, height: 0.5), capture, window)
            let (a, b) = (try #require(edge.first), try #require(above.first))
            let darker = [16, 8, 0].allSatisfy { Int(b >> UInt32($0) & 0xFF) - Int(a >> UInt32($0) & 0xFF) >= 8 }
            #expect(darker, "separator at lane \(lane): \(String(a, radix: 16)) against \(String(b, radix: 16))")
        }
        await model.close()
    }
}
