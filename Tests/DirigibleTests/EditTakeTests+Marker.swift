import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// F107 C8b: the feedback of a take marker. The ruler highlights the new flag for 0.3 s unless
/// Reduce Motion is on, and VoiceOver hears the marker name once at low priority.
extension EditTakeTests {
    /// The flag is lit at the press and 0.29 s later, and not at 0.30 s. A draw of the lit flag
    /// draws one outline, and a draw at 0.30 s draws none. With Reduce Motion on, no flag is lit.
    /// Controls: an add while idle lights nothing.
    @Test func theNewTakeFlagHighlightsUnlessReduceMotion() async throws {
        let (model, studio, window, view) = try await openLanes(app, try await package())
        studio.environment = hal.environment
        let ruler = view.ruler
        model.run(.addMarker)
        #expect(ruler.highlight == nil, "an idle add lit a flag")
        await model.record()
        #expect(studio.transport == .recording(take: 1))
        await hal.feed(seconds: 0.2)
        let t0 = ContinuousClock.now
        ruler.now = { t0 }

        ruler.reducesMotion = { true }
        model.run(.addMarker)
        let quiet = try #require(model.timeline.marker)
        #expect(!ruler.highlights(quiet) && ruler.highlight == nil, "Reduce Motion lit a flag")

        ruler.reducesMotion = { false }
        model.run(.addMarker)
        let lit = try #require(model.timeline.marker)
        #expect(lit != quiet && ruler.highlights(lit), "no highlight at the press")
        #expect(!ruler.highlights(quiet), "the other flag is lit")
        await until("the ruler gets the new flag") { ruler.inputs?.markers[lit] != nil }
        let outlines = ruler.highlightDraws
        ruler.needsDisplay = true
        drawNow(window)
        #expect(ruler.highlightDraws == outlines + 1, "a draw of the lit flag drew no outline")
        ruler.now = { t0 + .milliseconds(290) }
        #expect(ruler.highlights(lit), "no highlight at 0.29 s")
        ruler.now = { t0 + .milliseconds(300) }
        #expect(!ruler.highlights(lit), "the highlight lasts 0.30 s")
        ruler.needsDisplay = true
        drawNow(window)
        #expect(ruler.highlightDraws == outlines + 1, "a draw at 0.30 s drew the outline")
        await hal.feed(seconds: 0.2)
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        await model.close()
    }

    /// On the real clock, the ruler draws again after the highlight time with no outline, with no
    /// other change that asks for a draw. Each pass before the highlight end draws what waits, so a
    /// draw after the end comes from a request after that pass.
    @Test func theTakeFlagOutlineClearsOnTheClock() async throws {
        let (model, studio, window, view) = try await openLanes(app, try await package())
        studio.environment = hal.environment
        let ruler = view.ruler
        ruler.reducesMotion = { false }
        await model.record()
        #expect(studio.transport == .recording(take: 1))
        await hal.feed(seconds: 0.2)

        model.run(.addMarker)
        let lit = try #require(model.timeline.marker)
        let end = try #require(ruler.highlight?.end)
        var (draws, outlines) = (ruler.draws, ruler.highlightDraws)
        await until(limit: .seconds(1), "no ruler draw after the highlight time") {
            let late = ContinuousClock.now >= end
            drawNow(window)
            if late { return ruler.draws > draws }
            (draws, outlines) = (ruler.draws, ruler.highlightDraws)
            return false
        }

        #expect(!ruler.highlights(lit) && ruler.highlightDraws == outlines, "a late draw lit the flag")
        await hal.feed(seconds: 0.2)
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        await model.close()
    }

    /// One key-down and its key repeat make one announcement: the name of the marker, at low
    /// priority. Control: a second key-down is a second announcement.
    @Test func aTakeMarkerAnnouncesItsName() async throws {
        let (model, studio, window, _) = try await openLanes(app, try await package())
        studio.environment = hal.environment
        await model.record()
        #expect(studio.transport == .recording(take: 1))
        await hal.feed(seconds: 0.2)
        var heard: [(String, NSAccessibilityPriorityLevel)] = []
        model.chrome?.announce = { text, priority in heard.append((text, priority)) }

        app.timeline(.addMarker, event: returnKey(in: window), in: window)
        app.timeline(.addMarker, event: returnKey(in: window, repeats: true), in: window)

        #expect(heard.map(\.0) == [L10n.markerDefaultName.format(1)] && heard.map(\.1) == [.low], "\(heard)")
        app.timeline(.addMarker, event: returnKey(in: window), in: window)
        #expect(heard.map(\.0) == [L10n.markerDefaultName.format(1), L10n.markerDefaultName.format(2)])
        await hal.feed(seconds: 0.2)
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        await model.close()
    }
}
