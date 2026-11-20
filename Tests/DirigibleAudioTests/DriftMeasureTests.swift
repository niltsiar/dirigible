import Accelerate
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The drift points of one read, and the cut between two segments (decision 0077 D6 and D8), on
/// packages of the drift signal.
struct DriftMeasureTests {
    /// A 10 min clip at 100 ppm.
    @Test func eachWindowLagIsOnTheTrueLine() throws {
        try Self.expectOnePointOnTheLineInEachCell(DriftPackage(seconds: 600))
    }

    @Test func aSessionAt44100MeasuresTheLine() throws {
        try Self.expectOnePointOnTheLineInEachCell(DriftPackage(rate: 44_100, seconds: 600))
    }

    /// The reference of cells 2 and 7 is another voice: those windows give no point, and the fit of
    /// the 8 points gives the rate within 0.1 ppm and the offset within 0.1 ms.
    @Test func windowsInADropoutGiveNoPoint() throws {
        let (voice, other) = (DriftSignal(seed: 1, seconds: 700), DriftSignal(seed: 2, seconds: 700))
        let drift = try DriftPackage(
            seconds: 600, voice: voice,
            reference: { drift, range in drift.reference(range, voice: voice, other: other, replaced: [2, 7]) })
        let points = try drift.measure().points
        #expect(points.map { drift.cellIndex($0.clipFrame) } == [0, 1, 3, 4, 5, 6, 8, 9])
        let fit = try DriftFit(points: points, sampleRate: Double(drift.rate))
        #expect(fit.segments.count == 1)
        #expect(fit.outliers.isEmpty)
        #expect(abs(fit.slope - drift.m) * 1e6 < 0.1, "rate \(fit.slope * 1e6) ppm")
        let offsetError = (fit.segments[0].offset - Double(drift.offset)) * 1000 / Double(drift.rate)
        #expect(abs(offsetError) < 0.1, "offset \(offsetError) ms off")
    }

    /// The reference holds the clip voice in the odd cells, another voice alone in the even cells,
    /// and both voices in cell 3.
    @Test func anotherVoiceInTheReferenceDoesNotMoveThePoints() throws {
        let (voice, other) = (DriftSignal(seed: 1, seconds: 700), DriftSignal(seed: 2, seconds: 700))
        let drift = try DriftPackage(
            seconds: 600, voice: voice,
            reference: { drift, range in
                drift.reference(range, voice: voice, other: other, replaced: [0, 2, 4, 6, 8], added: [3])
            })
        let points = try drift.measure().points
        #expect(Set(points.map { drift.cellIndex($0.clipFrame) }).isSuperset(of: [1, 3, 5, 7, 9]))
        for point in points {
            let error = point.lag - drift.trueLag(point.clipFrame)
            #expect(abs(error) <= 5, "point at \(point.clipFrame): \(error) frames off")
        }
    }

    @Test func aSilentCellGivesNoPoint() throws {
        let voice = DriftSignal(seed: 1, seconds: 700)
        let drift = try DriftPackage(
            seconds: 600, voice: voice,
            clip: { drift, range in
                var samples = voice.clip(drift, range)
                for frame in drift.cell(4).clamped(to: range) { samples[frame - range.lowerBound] = 0 }
                return samples
            })
        let points = try drift.measure().points
        #expect(points.map { drift.cellIndex($0.clipFrame) } == [0, 1, 2, 3, 5, 6, 7, 8, 9])
    }

    /// A 12 min clip at 100 ppm, whose source skips 20 s at clip minute 5.5.
    @Test func aPauseUnder60sIsFoundNearTheLag() throws {
        try Self.expectOnePointOnItsLineAroundThePause(DriftPackage(seconds: 720, pause: 20, at: 330))
    }

    /// A skip of 90 s: the windows on the other side of the pause from the 0076 lag find no match
    /// within 60 s.
    @Test func aPauseOver60sIsFoundByTheWholeSpan() throws {
        try Self.expectOnePointOnItsLineAroundThePause(DriftPackage(seconds: 720, pause: 90, at: 330))
    }

    /// The reference holds another voice in cells 1 to 3 and 6 to 8: two runs of windows with no
    /// match. The 0076 read and the two runs build the full-span coarse scores twice: once for the
    /// read, and once for both runs.
    @Test func twoLostRunsBuildTheFullSpanScoresOnce() throws {
        let (voice, other) = (DriftSignal(seed: 1, seconds: 700), DriftSignal(seed: 2, seconds: 700))
        let drift = try DriftPackage(
            seconds: 600, voice: voice,
            reference: { drift, range in
                drift.reference(range, voice: voice, other: other, replaced: [1, 2, 3, 6, 7, 8])
            })
        var lengths: [vDSP_Length] = []
        let session = drift.package.session
        let points = try driftMeasure(
            of: "C", to: "ref", in: session, package: drift.package.url, span: session.syncSpan("C", to: "ref"),
            makeSetup: { setup, length, direction in
                if direction == .FORWARD { lengths.append(length) }
                return vDSP_DFT_zrop_CreateSetup(setup, length, direction)
            }
        ).points
        #expect(points.map { drift.cellIndex($0.clipFrame) } == [0, 4, 5, 9])
        let full = try #require(lengths.max())
        #expect(lengths.filter { $0 == full }.count == 2, "forward setup lengths \(lengths)")
    }

    /// Continuous speech from clip second 320 to 341 through a 100 ms and a 20 s skip: the cut is
    /// within 50 ms of the pause point.
    @Test func theCutIsAtTheGapInContinuousSpeech() throws {
        for pause in [0.1, 20] {
            var voice = DriftSignal(seed: 1, seconds: 30 + 720 * 1.01 + pause + 60)
            voice.set(speech: true, in: 30 + 320..<30 + 341 + pause)
            let drift = try DriftPackage(seconds: 720, pause: pause, at: 330, voice: voice)
            let cuts = try drift.cuts()
            #expect(cuts.count == 1, "pause \(pause) s: \(cuts.count) cuts")
            let error = try #require(cuts.first) - drift.pauseAt
            #expect(abs(error) <= drift.rate / 20, "pause \(pause) s: the cut is \(error) frames off")
        }
    }

    /// Speech up to 0.5 s before the pause point and silence there: the cut is within 50 ms of the
    /// pause point or inside the silence of the clip that holds it.
    @Test func theCutIsInTheSilenceAtThePause() throws {
        var voice = DriftSignal(seed: 1, seconds: 30 + 720 * 1.01 + 20 + 60)
        let pauseSource = 30 + 330 * (1 + 100e-6)
        voice.set(speech: false, in: pauseSource - 0.5..<pauseSource)
        let drift = try DriftPackage(seconds: 720, pause: 20, at: 330, voice: voice)
        let cuts = try drift.cuts()
        #expect(cuts.count == 1)
        let cut = try #require(cuts.first)
        let ms = drift.rate / 1000
        var (low, high) = (drift.pauseAt - ms, drift.pauseAt)
        while !voice.speaks(at: drift.sourceTime(Double(low - ms))) { low -= ms }
        while !voice.speaks(at: drift.sourceTime(Double(high))) { high += ms }
        let near = abs(cut - drift.pauseAt) <= drift.rate / 20
        #expect(
            near || (low...high).contains(cut),
            "the cut is \(cut - drift.pauseAt) frames from the pause, the silence \(low - drift.pauseAt)...\(high - drift.pauseAt)"
        )
    }

    /// Each 60 s cell gives one point, its window 10 s inside the cell, and each lag is within 0.1 ms
    /// (5 frames at 48 kHz and at 44.1 kHz) of the true lag at the window center.
    private static func expectOnePointOnTheLineInEachCell(_ drift: DriftPackage) throws {
        let points = try drift.measure().points
        #expect(points.count == drift.length / (60 * drift.rate))
        for (index, point) in points.enumerated() {
            let cell = drift.cell(index)
            let first = Double(cell.lowerBound + 5 * drift.rate)
            let last = Double(cell.upperBound - 5 * drift.rate)
            #expect(first <= point.clipFrame && point.clipFrame <= last, "point \(index) at \(point.clipFrame)")
            let error = point.lag - drift.trueLag(point.clipFrame)
            #expect(abs(error) <= 5, "point \(index): \(error) frames off")
        }
    }

    /// Each cell but the cell of the pause gives one point on its true line, before or after the
    /// pause; the window of the cell of the pause gives no point or a point on one of the two lines.
    private static func expectOnePointOnItsLineAroundThePause(_ drift: DriftPackage) throws {
        let points = try drift.measure().points
        let pauseCell = drift.cellIndex(Double(drift.pauseAt))
        let cells = points.map { drift.cellIndex($0.clipFrame) }
        #expect(cells.filter { $0 != pauseCell } == (0..<12).filter { $0 != pauseCell })
        let skip = drift.pause * Double(drift.rate)
        for point in points {
            let line = Double(drift.offset) + drift.m * point.clipFrame
            let error =
                drift.cellIndex(point.clipFrame) == pauseCell
                ? min(abs(point.lag - line), abs(point.lag - line - skip))
                : abs(point.lag - drift.trueLag(point.clipFrame))
            #expect(error <= 5, "point at \(point.clipFrame): \(error) frames off")
        }
    }
}
