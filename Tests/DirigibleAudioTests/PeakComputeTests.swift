import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The peak compute of decision 0017 (timeline-view criterion 1).
struct PeakComputeTests {
    static let stamp = FileStamp(size: 1, seconds: 2, nanoseconds: 3)

    /// The peaks of a pool file of `package`, with a pause that always goes on.
    static func compute(_ package: MixPackage, _ id: FileID) async throws -> Peaks {
        let file = try AVAudioFile(forReading: package.url.appending(path: "Clips/\(id.rawValue).wav"))
        return try await computePeaks(file, stamp: stamp) { .go }
    }

    /// 1 s of a 0.5 sine, then 1 s of silence, five times. 375 Hz gives 2 whole periods per
    /// 256-frame bin, so the RMS of a sine bin is 0.5 / sqrt(2).
    @Test func aSineAndSilenceGiveTheirBins() async throws {
        let package = try MixPackage()
        let second = sine(seconds: 1, rate: 48_000, frequency: 375)
        let samples = (0..<5).flatMap { _ in second + [Float](repeating: 0, count: 48_000) }
        try package.addFile("a", channels: [samples])

        let peaks = try await Self.compute(package, "a")

        #expect(peaks.frames == 480_000)
        #expect(peaks.levels.map(\.count) == [1875, 118, 8])
        for (index, bin) in peaks.levels[0].enumerated() {
            let first = index * 256 % 96_000
            if first + 256 <= 48_000 {
                #expect(abs(Double(bin.peak) / Double(UInt32.max) - 0.5) <= 0.0005, "sine bin \(index)")
                #expect(abs(Double(bin.rms) / Double(UInt32.max) - 0.354) <= 0.005, "sine bin \(index)")
            } else if first >= 48_000 && first + 256 <= 96_000 {
                #expect(bin == PeakColumn(peak: 0, rms: 0), "silence bin \(index)")
            }
        }
    }

    /// The first half has a silent left and a 0.5 right. The second half has 0.5 on both
    /// channels in phase: the peak is the maximum of the channels, not the sum.
    @Test func aStereoFileTakesTheLouderChannel() async throws {
        let package = try MixPackage()
        let tone = sine(seconds: 0.5, rate: 48_000, frequency: 375)
        let silence = [Float](repeating: 0, count: tone.count)
        try package.addFile("s", channels: [silence + tone, tone + tone])

        let peaks = try await Self.compute(package, "s")

        let bins = peaks.levels[0]
        #expect(bins.count == 188)
        #expect(bins[0..<93].allSatisfy { abs(Double($0.peak) / Double(UInt32.max) - 0.5) <= 0.0005 })
        #expect(bins[94..<188].allSatisfy { abs(Double($0.peak) / Double(UInt32.max) - 0.5) <= 0.0005 })
    }

    /// A 24-bit sine at -110 dBFS (about 26.5 steps of 24 bits) keeps its level in each level of
    /// bins: a peak of -110 dBFS and an RMS of -113 dBFS, within the 24-bit steps.
    @Test func aQuietSignalKeepsItsHeight() async throws {
        let package = try MixPackage()
        let scale = Float(pow(10, -110.0 / 20) / 0.5)
        try package.addFile("q", channels: [sine(seconds: 2, rate: 48_000, frequency: 375).map { $0 * scale }])

        let peaks = try await Self.compute(package, "q")

        func decibels<Value: FixedWidthInteger>(_ value: Value) -> Double {
            20 * log10(Double(value) / Double(Value.max))
        }
        for (index, level) in peaks.levels.enumerated() {
            let full = level.dropLast()
            #expect(!full.isEmpty && full.allSatisfy { abs(decibels($0.peak) + 110) <= 0.5 }, "peaks of level \(index)")
            #expect(full.allSatisfy { abs(decibels($0.rms) + 113.01) <= 0.5 }, "RMS of level \(index)")
        }
    }

    /// A DC level per 256-frame bin: bins 0..<16 hold 1/16, 2/16, 3/16, 4/16 in turn, bins
    /// 16..<432 are silent, and bins 432..<512 hold 4/16. A level k/16 stores k x 2^28.
    static func steps() throws -> MixPackage {
        let package = try MixPackage()
        var samples = [Float](repeating: 0, count: 131_072)
        for bin in 0..<16 {
            for frame in bin * 256..<(bin + 1) * 256 { samples[frame] = Float(bin % 4 + 1) / 16 }
        }
        for frame in 432 * 256..<131_072 { samples[frame] = 0.25 }
        try package.addFile("steps", channels: [samples])
        return package
    }

    @Test func anUpperBinIsTheMaximumOfSixteen() async throws {
        let peaks = try await Self.compute(try Self.steps(), "steps")

        #expect(peaks.levels.map(\.count) == [512, 32, 2])
        #expect(peaks.levels[0][0..<4].map(\.peak) == [268_435_456, 536_870_912, 805_306_368, 1_073_741_824])
        #expect(peaks.levels[1][0] == PeakColumn(peak32: 1_073_741_824, rms32: 735_140_772))
        #expect(peaks.levels[1][1] == PeakColumn(peak: 0, rms: 0))
        #expect(peaks.levels[1][27] == PeakColumn(peak32: 1_073_741_824, rms32: 1_073_741_824))
        #expect(
            peaks.levels[2] == [
                PeakColumn(peak32: 1_073_741_824, rms32: 183_785_193),
                PeakColumn(peak32: 1_073_741_824, rms32: 600_239_927),
            ])
    }

    @Test func fillReadsTheLargestLevelAtOrBelowTheStep() async throws {
        let peaks = try await Self.compute(try Self.steps(), "steps")
        func fill(count: Int, step: Double) -> [PeakColumn] {
            var columns = [PeakColumn](repeating: PeakColumn(peak: 1, rms: 1), count: count)
            peaks.fill(&columns, from: 0, step: step)
            return columns
        }
        let zero = PeakColumn(peak: 0, rms: 0)

        func level(_ sixteenths: UInt32) -> PeakColumn { PeakColumn(peak32: sixteenths << 28, rms32: sixteenths << 28) }
        let quarter: UInt32 = 1_073_741_824

        #expect(fill(count: 5, step: 256) == [level(1), level(2), level(3), level(4), level(1)])
        #expect(fill(count: 2, step: 4096) == [PeakColumn(peak32: quarter, rms32: 735_140_772), zero])
        #expect(
            fill(count: 3, step: 100_000) == [
                PeakColumn(peak32: quarter, rms32: 600_239_927), PeakColumn(peak32: quarter, rms32: 600_239_927), zero,
            ])
    }

    /// A truncated WAV opens with its real length (probe E6e); the compute stops there.
    @Test func aShortReadStopsAtTheRealLength() async throws {
        let package = try MixPackage()
        try package.addFile("short", channels: [[Float](repeating: 0.25, count: 48_000)])
        let real = try package.truncate("short", toBytes: 30_000)

        let peaks = try await Self.compute(package, "short")

        #expect(real > 0 && real < 48_000)
        #expect(peaks.frames == Frames(real))
        #expect(peaks.levels[0].count == (real + 255) / 256)
    }

    @Test func aStopEndsTheCompute() async throws {
        let package = try MixPackage()
        try package.addFile("a", channels: [[Float](repeating: 0.25, count: 48_000)])
        let file = try AVAudioFile(forReading: package.url.appending(path: "Clips/a.wav"))

        await #expect(throws: PeakError.cancelled) {
            try await computePeaks(file, stamp: Self.stamp) { .stop }
        }
    }

    /// A pause that waited: the file can have changed during the take, so the pass opens it again.
    @Test func aWaitRestartsTheCompute() async throws {
        let package = try MixPackage()
        try package.addFile("a", channels: [[Float](repeating: 0.25, count: 600_000)])
        let file = try AVAudioFile(forReading: package.url.appending(path: "Clips/a.wav"))
        let calls = StepCounter(fails: { $0 >= 2 })

        await #expect(throws: PeakError.restart) {
            try await computePeaks(file, stamp: Self.stamp) { calls.next() ? .waited : .go }
        }
        #expect(calls.calls == 2)
    }
}
