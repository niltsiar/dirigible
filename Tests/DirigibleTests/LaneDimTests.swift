import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Mute and solo C11 (decision 0039): the lane of each track that is not heard gets one dim layer
/// over the lane pixels, with no lane redraw.
@Suite(.serialized) @MainActor struct LaneDimTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
    }

    func open(tracks: Int) async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: tracks, seconds: 20, audio: true, noise: true))
    }

    /// The frames of the dim layers, top lane first.
    func dims(_ view: TimelineScrollView) -> [NSRect] {
        (view.lanes.dim.layer.sublayers ?? []).map(\.frame).sorted { $0.minY < $1.minY }
    }

    /// The rect of lane `lane` in the document view.
    func laneRect(_ lane: Int, _ view: TimelineScrollView) throws -> NSRect {
        let height = try #require(view.lanes.inputs?.laneHeight)
        return NSRect(x: 0, y: Double(lane) * height, width: view.lanes.bounds.width, height: height)
    }

    /// C11 a to e: a mute and a solo give one layer over the lane of t1, an unmute removes it, the
    /// lane pixels do not change, and a lane height change and a track move keep the layer on the
    /// lane rect.
    @Test func aMutedTrackGetsOneDimLayerAndNoPixelChange() async throws {
        let (model, studio, window, view) = try await open(tracks: 3)
        drawNow(window)
        let lanes = view.lanes
        let height = try #require(lanes.inputs?.laneHeight)
        let (column, row) = (Int(40 * window.backingScaleFactor), Int(height / 2 * window.backingScaleFactor))
        let before = try #require(lanes.surfaces.pixel(column: column, row: row), "a lane pixel of t1")
        let draws = lanes.draws
        #expect(dims(view).isEmpty, "no dim with no flag")

        model.setFlag(.muted, true, track: "t1", all: false)
        await until("the dim of t1") { dims(view).count == 1 }
        #expect(dims(view) == [try laneRect(0, view)], "a: one layer on the lane of t1")
        let color = try #require(lanes.dim.layer.sublayers?.first?.backgroundColor)
        let lane = lanes.palette.lane
        let expected = CGColor(
            srgbRed: Double(lane >> 16 & 0xFF) / 255, green: Double(lane >> 8 & 0xFF) / 255,
            blue: Double(lane & 0xFF) / 255, alpha: 0.5)
        #expect(color == expected, "a: the lane color at 50 %: \(color)")
        drawNow(window)
        #expect(lanes.surfaces.pixel(column: column, row: row) == before, "d: the lane pixel of t1 stays")
        #expect(lanes.draws == draws, "d: a mute draws no lane: \(lanes.draws - draws) draws")

        model.setFlag(.muted, false, track: "t1", all: false)
        model.setFlag(.soloed, true, track: "t2", all: false)
        await until("the dim of t1 and t3") { dims(view).count == 2 }
        #expect(dims(view) == [try laneRect(0, view), try laneRect(2, view)], "b: a solo of t2 dims t1 and t3")
        model.setFlag(.soloed, false, track: "t2", all: false)
        drawNow(window)
        await until("no dim") { dims(view).isEmpty }
        #expect(dims(view).isEmpty, "c: no flag, no dim")

        model.setFlag(.muted, true, track: "t3", all: false)
        model.timeline.laneHeight = .fixed(height == 80 ? 100 : 80)
        await until("the new lane height") { lanes.inputs?.laneHeight != height && dims(view).count == 1 }
        #expect(dims(view) == [try laneRect(2, view)], "e: a lane height change keeps the lane rect")
        try studio.edit { session throws(SessionError) in try session.removeTrack("t1") }
        await until("t3 is lane 1") { lanes.inputs?.session.tracks.count == 2 }
        #expect(dims(view) == [try laneRect(1, view)], "e: a track move keeps the lane rect")
        await model.close()
    }

    /// C11 g: the dim color is the lane color of the palette of the appearance.
    @Test func anAppearanceChangeSetsTheDimColorAgain() async throws {
        let (model, _, window, view) = try await open(tracks: 2)
        model.setFlag(.muted, true, track: "t2", all: false)
        await until("the dim of t2") { dims(view).count == 1 }
        for (appearance, name) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            window.appearance = NSAppearance(named: appearance)
            drawNow(window)
            let lane = LanePalette.pick(for: try #require(NSAppearance(named: appearance))).lane
            let color = try #require(view.lanes.dim.layer.sublayers?.first?.backgroundColor?.components)
            let expected = [lane >> 16 & 0xFF, lane >> 8 & 0xFF, lane & 0xFF].map { Double($0) / 255 } + [0.5]
            #expect(
                zip(color, expected).allSatisfy { abs($0 - $1) < 0.002 }, "\(name): \(color) against \(expected)")
        }
        await model.close()
    }
}
