import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The partial live draws give the pixels of a full draw of the same state (live take view,
/// Phase 7 findings V1 and V2). A partial draw changes only its dirty rect, so a column that an
/// input changes outside that rect keeps old pixels on screen.
extension TimelineLiveTests {
    /// The front pixels of `lanes` in the columns from `from` to `to` seconds; nil for a row
    /// outside the surface. It reads each row once: a read per pixel (`pixel(column:row:)` copies
    /// the row) held the main actor for seconds, and a play test of another suite failed.
    func pixels(_ take: Lanes, from: Double, to: Double, lanes: Range<Int>) throws -> [[UInt32]?] {
        let window = try #require(take.view.lanes.surfaces.shown)
        let first = window.pixels.columns.lowerBound
        let columns = try take.column(from) - first..<take.column(to) - first
        return window.rows(of: lanes).map { take.view.lanes.surfaces.frontRow($0).map { Array($0[columns]) } }
    }

    /// The columns from `from` to `to` seconds after the partial draws, and after a full draw of
    /// the same state: the number of pixels that differ.
    func partialMinusFull(_ take: Lanes, from: Double, to: Double, lanes: Range<Int>) throws -> Int {
        let partial = try pixels(take, from: from, to: to, lanes: lanes)
        take.view.lanes.needsDisplay = true
        drawNow(take.window)
        let full = try pixels(take, from: from, to: to, lanes: lanes)
        let (before, after) = (partial.compactMap { $0 }, full.compactMap { $0 })
        try #require(!before.isEmpty && before.count == partial.count && after.count == before.count)
        return zip(before, after).map { zip($0, $1).filter { $0 != $1 }.count }.reduce(0, +)
    }

    /// V1 at the take start: the first span of t2 starts 300 ms after the take start, after a
    /// partial draw of t1 drew the box of t2 to the head. The full draw shows the lane color
    /// from the take start to that span.
    @Test func aLateFirstSpanDrawsTheGapAsAFullDraw() async throws {
        let lanes = try await take(armed: ["t1", "t2"])
        lanes.report(0.1, 0.15, track: "t1")
        lanes.tick(0.2)
        lanes.report(0.15, 0.35, track: "t1")
        lanes.report(0.3, 0.35, track: "t2")
        lanes.tick(0.4)
        let rows = try #require(lanes.view.lanes.surfaces.shown).laneRows

        let differ = try partialMinusFull(lanes, from: 0, to: 0.4, lanes: 0..<2)

        #expect(differ == 0, "\(differ) pixels differ from a full draw")
        let palette = lanes.view.lanes.palette
        // Before the take label chip, which starts 2 pt after the take start (ClipLabel).
        #expect(try lanes.runs(at: 0.005, lane: 1) == [Run(palette.lane, rows)], "the gap before the first span")
        await lanes.close()
    }

    /// V1 after a covered span: the next span starts 300 ms after the last covered frame, and
    /// the last partial draw drew the box past that frame. No track state changes, so no full
    /// draw comes between.
    @Test func aGapAfterACoveredSpanDrawsAsAFullDraw() async throws {
        let lanes = try await take()
        lanes.report(0, 0.5)
        lanes.tick(0.6)
        lanes.report(0.8, 0.9)
        lanes.tick(1)
        let rows = try #require(lanes.view.lanes.surfaces.shown).laneRows

        let differ = try partialMinusFull(lanes, from: 0, to: 1, lanes: 0..<1)

        #expect(differ == 0, "\(differ) pixels differ from a full draw")
        #expect(try lanes.runs(at: 0.55, lane: 0) == [Run(lanes.view.lanes.palette.lane, rows)], "the gap")
        await lanes.close()
    }

    /// V2: the box passes 60 pt (0.16 s at 128 frames per point) in partial draws, one span of
    /// 50 ms per tick. The take label at the box start shows whole, as in a full draw.
    @Test func theTakeLabelOfPartialDrawsIsWhole() async throws {
        let lanes = try await take()
        #expect(lanes.view.framesPerPoint == 128)
        for tick in 1...6 {
            let now = Double(tick) * 0.05
            lanes.report(now - 0.05, now)
            lanes.tick(now)
        }

        let differ = try partialMinusFull(lanes, from: 0, to: 0.3, lanes: 0..<1)

        #expect(differ == 0, "\(differ) pixels differ from a full draw")
        await lanes.close()
    }
}
