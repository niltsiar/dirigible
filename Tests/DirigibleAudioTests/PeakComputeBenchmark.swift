import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Compares a time with its budget. With -O (`make bench`), a miss fails the test. In debug, the
/// budget is a proxy that the load of the suite moves, so a miss only prints a report line.
func expectWithinBudget(
    _ value: Duration, _ budget: Duration, _ message: String, sourceLocation: SourceLocation = #_sourceLocation
) {
    #if DEBUG
        if value > budget { print("bench report: \(message) over debug budget \(budget)") }
    #else
        #expect(value <= budget, "\(message)", sourceLocation: sourceLocation)
    #endif
}

/// Timeline-view criterion 11: a 2 h mono WAV computes in 3 s or less (probe P1: 0.4 s warm).
struct PeakComputeBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func twoHoursComputeInThreeSeconds() async throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: "long.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let block = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000))
        block.frameLength = 480_000
        let tone = sine(seconds: 10, rate: 48_000, frequency: 375)
        block.floatChannelData![0].update(from: tone, count: tone.count)
        let writer = try ClipWriter(url: url, file: "long.wav", format: format)
        for _ in 0..<720 { try writer.write(block) }
        try writer.close()
        let file = try AVAudioFile(forReading: url)

        let clock = ContinuousClock()
        let start = clock.now
        let peaks = try await computePeaks(file, stamp: FileStamp(size: 0, seconds: 0, nanoseconds: 0)) { .go }
        let elapsed = clock.now - start

        #expect(peaks.frames == 345_600_000)
        #expect(peaks.levels[0].count == 1_350_000)
        expectWithinBudget(elapsed, .seconds(3), "the compute took \(elapsed)")
    }

    /// The cache of the peak precision: the 2 h fixture of the lane benches (6 tracks of 345,600,000
    /// frames, 1,439,649 bins of all levels a track) gives 6 files of 64 + 8 x 1,439,649 bytes, and
    /// 6 files of version 1 take 64 + 4 x 1,439,649 bytes each. Prints the bin arrays in memory and
    /// the cache folder size of both versions.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func theCacheFilesOfTwoHoursTakeEightBytesABin() throws {
        let frames = 345_600_000
        let levels = Peaks.binFrames.map { bin in
            [PeakColumn](
                repeating: PeakColumn(peak: 2_147_483_648, rms: 1_073_741_824), count: (frames + bin - 1) / bin)
        }
        let peaks = Peaks(
            frames: Frames(frames), stamp: FileStamp(size: 0, seconds: 0, nanoseconds: 0), channels: 1,
            sampleRate: 48_000, levels: levels)
        let bins = 6 * levels.map(\.count).reduce(0, +)

        let folder = try TemporaryFolder()
        let (current, earlier) = (folder.url.appending(path: "2"), folder.url.appending(path: "1"))
        try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
        let version1 = PeakFileTests.version1(peaks)
        for track in 1...6 {
            let path = "take1-\(track).wav"
            try PeakFile.write(peaks, path: path, in: current)
            try version1.write(
                to: earlier.appending(path: PeakFileTests.version1Name(PeakFile.escape(path), peaks.stamp)))
        }
        func sizes(_ folder: URL) throws -> [Int] {
            try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
                .map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
        }

        let (now, before) = (try sizes(current), try sizes(earlier))
        print("PeakComputeBenchmark bin arrays of 2 h, 6 tracks: \(bins * MemoryLayout<PeakColumn>.stride) bytes")
        print(
            "PeakComputeBenchmark cache folder of 2 h, 6 tracks: \(now.reduce(0, +)) bytes, version 1 \(before.reduce(0, +)) bytes"
        )
        #expect(now == Array(repeating: 11_517_256, count: 6), "the version 2 files")
        #expect(before == Array(repeating: 5_758_660, count: 6), "the version 1 files")
    }
}
