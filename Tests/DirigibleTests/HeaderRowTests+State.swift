import AppKit
import DirigibleCore
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 2026-10-11-ui-polish-header C3b: a two-line row of 56 to 79 pt has no room for the state
/// text and the "Privacy…" button, so the state is an orange symbol button that opens the
/// settings, with the full sentence as its help tag.
extension HeaderRowTests {
    /// The AppKit bezel views of the buttons in row `lane`: a text button has one; a borderless
    /// SwiftUI symbol button has none.
    func bezels(_ host: NSView, lane: Int, laneHeight: Double) -> Int {
        func leaves(_ view: NSView) -> [NSView] { view.subviews.isEmpty ? [view] : view.subviews.flatMap(leaves) }
        return leaves(host).filter { leaf in
            let frame = leaf.convert(leaf.bounds, to: host)
            return String(describing: type(of: leaf)) == "NSButtonBezelView"
                && frame.midY >= Double(lane) * laneHeight && frame.midY < Double(lane + 1) * laneHeight
        }.count
    }

    @Test func aMidRowShowsTheStateAsASymbolButton() async throws {
        let (model, studio) = try await model()
        studio.liveTracks["t1"] = LiveTrack(state: .noSound, droppedFrames: 0, peak: 0)
        studio.liveTracks["t2"] = LiveTrack(state: .recording, droppedFrames: 0, peak: 0)
        for lane in [56.0, 60] {
            for width in [180.0, 340] {
                let (window, host) = rows(model, studio, laneHeight: lane, width: width)
                let label = "\(lane) pt lanes at \(width) pt"
                let out = outside(host, width: width)
                #expect(out.isEmpty, "inside the row: \(label): \(out)")
                // Row 2 records with no state: row 1 has no more text buttons than it.
                #expect(
                    bezels(host, lane: 0, laneHeight: lane) == bezels(host, lane: 1, laneHeight: lane),
                    "no \"Privacy…\" text button: \(label)")
                window.orderFront(nil)
                drawNow(window)
                // The window server shows a flushed frame some milliseconds later: capture until
                // the symbol shows, for 5 s or less.
                let rect = host.convert(NSRect(x: 0, y: 0, width: width, height: lane), to: nil)
                let end = ContinuousClock.now + .seconds(5)
                var orange = 0
                repeat {
                    let capture = try await TimelineColorTests.capture(window)
                    orange = try TimelineRulerTests.pixels(of: rect, capture, window).filter(Self.isOrange).count
                } while orange <= 10 && ContinuousClock.now < end
                #expect(orange > 10, "the orange symbol shows: \(label)")
                window.close()
            }
        }
        await model.close()
    }

    /// Code gate 1 item 3: a quiet monitor puts its text on line 3 of a tall row, so line 2 keeps
    /// the fader. A row of 56 to 79 pt shows the quiet symbol in place of the fader.
    @Test func aTallQuietRowKeepsTheFader() async throws {
        let (model, studio) = try await model()
        (studio.listenRequest, studio.deviceReports) = (["t1"], ["mic": .quiet])
        #expect(studio.quietListens == ["t1"])
        for (height, faders) in [(100.0, 2), (60.0, 1)] {
            let (window, host) = rows(model, studio, laneHeight: height, width: 340)
            let found = controls(host, in: host).filter { $0.kind == "fader" }.count
            #expect(found == faders, "\(faders) faders at \(height) pt: \(found)")
            window.close()
        }
        (studio.listenRequest, studio.deviceReports) = ([], [:])
        await model.close()
    }

    /// C6: from 80 pt, line 1 stays at the row top, as in Hindenburg, Logic, and Final Cut Pro.
    /// Under 80 pt the row stays centered.
    @Test func aTallRowPinsLineOneToTheTop() async throws {
        let (model, studio) = try await model()
        func nameTop(_ lane: Double) throws -> Double {
            let (window, host) = rows(model, studio, laneHeight: lane, width: 340)
            defer { window.close() }
            return try #require(controls(host, in: host).first { $0.kind == "name" }).frame.minY
        }
        let tops = try [80.0, 100, 200].map(nameTop)
        #expect(tops.allSatisfy { $0 < 20 && $0 == tops[0] }, "line 1 at the top from 80 pt: \(tops)")
        let (low, mid) = (try nameTop(56), try nameTop(79))
        #expect(mid > low, "centered under 80 pt: \(low) at 56, \(mid) at 79")
        await model.close()
    }

    /// A height change in one form runs no row body: the rows get the form as a Bool.
    @Test func aLaneHeightChangeInOneFormRunsNoRowBody() async throws {
        let (model, studio) = try await model()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 400), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let height = HeightBox(value: 100)
        let host = NSHostingView(rootView: HeightHeaders(model: model, studio: studio, box: height))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 400)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        drawNow(window)
        model.headerRuns = (0, 0)
        height.value = 120
        // SwiftUI reads the change on a run loop pass.
        await until("the headers took the new height") {
            host.layoutSubtreeIfNeeded()
            drawNow(window)
            return model.headerRuns.headers > 0
        }
        // A row body in a later pass counts too.
        await runLoopPass()
        host.layoutSubtreeIfNeeded()
        drawNow(window)
        #expect(model.headerRuns.rows == 0, "no row body from 100 to 120 pt: \(model.headerRuns.rows)")
        window.close()
        await model.close()
    }
}

@Observable @MainActor final class HeightBox {
    var value: Double
    init(value: Double) { self.value = value }
}

/// The headers with a lane height that a test changes.
struct HeightHeaders: View {
    let model: SessionWindow
    let studio: Studio
    let box: HeightBox

    var body: some View {
        TrackHeaders(model: model, studio: studio, laneHeight: box.value, selected: [])
    }
}
