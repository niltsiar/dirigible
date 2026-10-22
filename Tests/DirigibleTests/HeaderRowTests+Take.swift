import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 2026-10-11-ui-polish-header C18 and C20: while a take is live (it records or finalizes),
/// a row shows its route as plain text and its name as a 13 pt text, as Logic and Hindenburg do.
/// A disabled pop-up and a disabled field read as broken. A placement, a level, or an import
/// keeps the disabled controls.
extension HeaderRowTests {
    /// The count of route menu hosts and name field hosts of the rows.
    func routesAndNames(_ host: NSView) -> (routes: Int, names: Int) {
        let found = controls(host, in: host)
        return (found.filter { $0.kind == "route" }.count, found.filter { $0.kind == "name" }.count)
    }

    @Test func aTakeShowsTheRouteAsText() async throws {
        let (model, studio) = try await model()
        let states: [(Studio.Transport, Bool, String)] = [
            (.idle, false, "at rest"),
            (.recording(take: 1), true, "a take"),
            (.finalizing(take: 1), true, "a finalize"),
            (.placing(SegmentName(take: 1, arm: 1, segment: 1)), false, "a placement"),
            (.leveling, false, "a level"),
            (.ducking, false, "a duck"),
            (.importing(ImportRun(name: "Voice.wav", kind: .file, flags: ImportFlags())), false, "an import"),
        ]
        for (transport, live, label) in states {
            studio.transport = transport
            #expect((transport.liveTake != nil) == live, "the one test of a live take: \(label)")
            let (window, host) = rows(model, studio, laneHeight: 100, width: 340)
            let (routes, names) = routesAndNames(host)
            let expected = live ? 0 : 2
            #expect(routes == expected && names == expected, "\(label): \(routes) routes, \(names) names")
            window.close()
        }
        // A retried finalize (`retryFinalize`) has no live peaks: the rows still show the take form.
        studio.transport = .finalizing(take: 1)
        studio.liveTracks = [:]
        let (window, host) = rows(model, studio, laneHeight: 50, width: 340)
        #expect(routesAndNames(host).names == 0, "a retried finalize")
        window.close()
        studio.transport = .idle
        await model.close()
    }

    /// C20: a level report of a take runs no row body and no header body. The take form reads the
    /// transport, and the rows read the live states: a level report changes neither (run
    /// 2026-10-16-observation-hang C1). The meter tests are in `HeaderMeterRateTests`.
    @Test func aTakeTickRunsNoRowBody() async throws {
        let (model, studio) = try await model()
        studio.transport = .recording(take: 1)
        studio.liveTracks["t1"] = LiveTrack(state: .recording, droppedFrames: 0, peak: 0.1)
        let (window, host) = rows(model, studio, laneHeight: 100, width: 340)
        await until("the rows ran their first bodies") { model.headerRuns.rows > 0 }
        await runLoopPass()
        drawNow(window)
        model.headerRuns = (0, 0)
        for tick in 0..<60 {
            studio.liveTracks["t1"]?.peak = Float(tick % 10) / 10
            await runLoopPass()
            host.layoutSubtreeIfNeeded()
            drawNow(window)
        }
        #expect(model.headerRuns.rows == 0, "row bodies over 60 ticks: \(model.headerRuns.rows)")
        // The take form reads the transport, not the level reports: no header body at a tick.
        #expect(model.headerRuns.headers == 0, "header bodies over 60 ticks: \(model.headerRuns.headers)")
        window.close()
        studio.transport = .idle
        await model.close()
    }
}
