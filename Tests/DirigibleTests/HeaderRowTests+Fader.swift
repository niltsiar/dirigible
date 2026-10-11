import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Track fader C7, C10, and C11 (F94): the fader on line 2 of a two-line row, from its measured
/// width, and only with no live state and no quiet text.
/// The faders under `view`, in subview order.
@MainActor func faderViews(_ view: NSView) -> [TrackFaderView] {
    (view as? TrackFaderView).map { [$0] } ?? view.subviews.flatMap(faderViews)
}

extension HeaderRowTests {
    /// The faders under `view`, top row first.
    func faders(_ view: NSView) -> [TrackFaderView] {
        faderViews(view).sorted { $0.convert($0.bounds, to: nil).minY > $1.convert($1.bounds, to: nil).minY }
    }

    /// C10: two-line rows show the fader from `faderTwoLineWidth`, where the route menu keeps
    /// `faderRouteWidth` and every view stays inside the row; one pt less hides it. One-line rows
    /// never show it.
    @Test func theFaderShowsOnlyWhereItFits() async throws {
        let (model, studio) = try await model(tracks: 3)
        let gate = TrackHeaders.faderTwoLineWidth
        #expect((180...340).contains(gate), "the default header width shows the fader: \(gate)")
        for (lane, width, expected) in [(100.0, gate, 3), (100, gate - 1, 0), (60, gate, 3), (50, 480, 0)] {
            let (window, host) = rows(model, studio, laneHeight: lane, width: width)
            let label = "\(lane) pt lanes at \(width) pt"
            #expect(faders(host).count == expected, "a fader in each row from the gate: \(label)")
            let out = outside(host, width: width)
            #expect(out.isEmpty, "inside the row: \(label): \(out)")
            if expected > 0 {
                let routes = controls(host, in: host).filter { $0.kind == "route" }.map(\.frame.width)
                #expect(
                    routes.count == 3 && routes.allSatisfy { $0 >= TrackHeaders.faderRouteWidth },
                    "the route menu keeps its width: \(label): \(routes)")
            }
            window.close()
        }
        await model.close()
    }

    /// C10: the live state of a take or a monitor, and the quiet text, take line 2: no fader.
    @Test func aLiveStateOrAQuietTextHidesTheFader() async throws {
        let (model, studio) = try await model(tracks: 3)
        studio.liveTracks["t1"] = LiveTrack(state: .monitoring, droppedFrames: 0, peak: 0.1)
        studio.listenRequest = ["t2"]
        studio.deviceReports["mic"] = .quiet
        let (window, host) = rows(model, studio, laneHeight: 100, width: 340)
        #expect(faders(host).map(\.slider.track) == ["t3"], "C10: only the row with no state shows a fader")
        window.close()
        await model.close()
    }

    @Test func theFaderIsOffDuringATake() async throws {
        let (model, studio) = try await model()
        studio.transport = .recording(take: 1)
        defer { studio.transport = .idle }
        let (window, host) = rows(model, studio, laneHeight: 100, width: 340)
        let found = faders(host)
        #expect(found.count == 2 && found.allSatisfy { !$0.slider.isEnabled }, "C10: the faders are off")
        window.close()
        await model.close()
    }

    /// Plan gate 1 item 1: a row body that runs during a drag (a monitor level report of another
    /// track) keeps the dragged value in the slider and in the readout, and the mouse-up commits it.
    @Test func aRowBodyDuringADragKeepsTheDraggedValue() async throws {
        let (model, studio) = try await model(tracks: 3)
        let (window, host) = rows(model, studio, laneHeight: 100, width: 340)
        let fader = try #require(faders(host).first)
        let position = FaderScale(start: 0).position(dB: -6)

        fader.slider.beginDrag()
        fader.slider.doubleValue = position
        fader.slider.sendAction(fader.slider.action, to: fader.slider.target)
        model.headerRuns.rows = 0
        studio.liveTracks["t3"] = LiveTrack(state: .monitoring, droppedFrames: 0, peak: 0.2)
        await until("the level report runs the row bodies") {
            drawNow(window)
            return model.headerRuns.rows > 0
        }

        // SwiftUI skips `updateNSView` when the inputs of the fader are equal, so the test also
        // calls the update with the session value, as SwiftUI does when an input changes.
        fader.update(model: model, track: "t1", name: "T1", dB: 0, enabled: true)
        #expect(fader.slider.doubleValue == position, "C7: the slider keeps the dragged value")
        #expect(fader.slider.shown == -6, "C7: the readout keeps the dragged value")
        fader.slider.endDrag()
        #expect(studio.session.track("t1")?.gain.dB == -6, "C7: the mouse-up commits the dragged value")
        window.close()
        await model.close()
    }

    /// C11: a drag step writes no state that a row reads, so no row body runs.
    @Test func aFaderDragRunsNoRowBody() async throws {
        let (model, studio) = try await model(tracks: 3)
        let (window, host) = rows(model, studio, laneHeight: 100, width: 340)
        let slider = try #require(faders(host).first).slider

        slider.beginDrag()
        model.headerRuns.rows = 0
        for dB in [-1.0, -2, -3, -4, -5] {
            slider.doubleValue = FaderScale(start: 0).position(dB: dB)
            slider.sendAction(slider.action, to: slider.target)
            // A turn of the main run loop, where SwiftUI runs the bodies of changed rows.
            try await Task.sleep(for: .milliseconds(20))
            drawNow(window)
        }
        #expect(model.headerRuns.rows == 0, "C11: no row body during the drag: \(model.headerRuns.rows)")
        slider.endDrag()
        #expect(studio.session.track("t1")?.gain.dB == -5)
        window.close()
        await model.close()
    }
}
