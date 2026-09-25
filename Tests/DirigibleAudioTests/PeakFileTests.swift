import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The peak cache file of decision 0017, version 1 (timeline-view criterion 2).
struct PeakFileTests {
    static let stamp = FileStamp(size: 1_036_804_096, seconds: 1_790_293_732, nanoseconds: 540_000_123)

    /// The peaks of 70,000 frames of a mono ramp at 48 kHz.
    static func peaks() async throws -> Peaks {
        let package = try MixPackage()
        try package.addFile("a", channels: [ramp(frames: 70_000)])
        let file = try AVAudioFile(forReading: package.url.appending(path: "Clips/a.wav"))
        return try await computePeaks(file, stamp: stamp) { .go }
    }

    static func decode(_ data: Data, stamp: FileStamp = stamp, channels: Int = 1, rate: Int = 48_000) -> Peaks? {
        PeakFile.decode(data, stamp: stamp, channels: channels, rate: rate)
    }

    /// Build values through the compute, encode, decode, and compare (the tdd writer and reader rule).
    @Test func aRandomEnvelopeRoundTrips() async throws {
        var random = SeededGenerator(seed: 17)
        for _ in 0..<4 {
            let channels = Int.random(in: 1...2, using: &random)
            let frames = Int.random(in: 1...300_000, using: &random)
            let envelope = (0..<channels).map { _ in
                (0..<frames).map { _ in
                    Float.random(in: -1...1, using: &random) * Float.random(in: 0...1, using: &random)
                }
            }
            let package = try MixPackage()
            try package.addFile("r", channels: envelope)
            let file = try AVAudioFile(forReading: package.url.appending(path: "Clips/r.wav"))
            let stamp = FileStamp(
                size: Int64.random(in: 0...(1 << 40), using: &random),
                seconds: Int.random(in: 0...(1 << 34), using: &random),
                nanoseconds: Int.random(in: 0..<1_000_000_000, using: &random))
            let peaks = try await computePeaks(file, stamp: stamp) { .go }

            let data = PeakFile.encode(peaks)

            #expect(data.count == 64 + 4 * peaks.levels.map(\.count).reduce(0, +))
            #expect(PeakFile.decode(data, stamp: stamp, channels: channels, rate: 48_000) == peaks)
        }
    }

    /// Each row of the format table: change one field, and the reader refuses the file.
    @Test(arguments: [
        ("magic", 0, UInt64(0x5859_5A)),
        ("version", 8, UInt64(2)),
        ("binFrames", 12, UInt64(512)),
        ("levels", 16, UInt64(2)),
        ("reserved", 28, UInt64(1)),
    ])
    func aChangedHeaderFieldIsRefused(field: String, offset: Int, value: UInt64) async throws {
        var data = PeakFile.encode(try await Self.peaks())
        #expect(Self.decode(data) != nil)

        withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian) {
            data.replaceSubrange(offset..<offset + 4, with: $0)
        }

        #expect(Self.decode(data) == nil, "\(field)")
    }

    @Test func anotherChannelCountIsRefused() async throws {
        let data = PeakFile.encode(try await Self.peaks())
        #expect(Self.decode(data, channels: 1) != nil)
        #expect(Self.decode(data, channels: 2) == nil)
    }

    @Test func anotherRateIsRefused() async throws {
        let data = PeakFile.encode(try await Self.peaks())
        #expect(Self.decode(data, rate: 48_000) != nil)
        #expect(Self.decode(data, rate: 44_100) == nil)
    }

    /// A WAV that changed after the compute (another size or mtime) is a miss.
    @Test func aStaleStampIsRefused() async throws {
        let data = PeakFile.encode(try await Self.peaks())
        let s = Self.stamp
        #expect(Self.decode(data, stamp: s) != nil)
        #expect(
            Self.decode(data, stamp: FileStamp(size: s.size + 1, seconds: s.seconds, nanoseconds: s.nanoseconds)) == nil
        )
        #expect(
            Self.decode(data, stamp: FileStamp(size: s.size, seconds: s.seconds + 1, nanoseconds: s.nanoseconds)) == nil
        )
        #expect(
            Self.decode(data, stamp: FileStamp(size: s.size, seconds: s.seconds, nanoseconds: s.nanoseconds + 1)) == nil
        )
    }

    /// The bin counts derive from the frames, so a frame count that does not match the bins
    /// gives another file size. A frame count over 2^40 needs a file over 17 GB, so the size
    /// check also refuses it; the largest count must not trap.
    @Test func aFileSizeThatDoesNotMatchTheFramesIsRefused() async throws {
        let data = PeakFile.encode(try await Self.peaks())
        func frames(_ value: UInt64) -> Data {
            var changed = data
            withUnsafeBytes(of: value.littleEndian) { changed.replaceSubrange(56..<64, with: $0) }
            return changed
        }
        let more = frames(70_000 + 256)
        #expect(Self.decode(frames(70_000 + 1)) != nil)
        #expect(Self.decode(frames(1 << 40 + 1)) == nil)
        #expect(Self.decode(frames(.max)) == nil)

        #expect(Self.decode(data.dropLast(4)) == nil)
        #expect(Self.decode(data + Data(count: 4)) == nil)
        #expect(Self.decode(data + Data(count: 2)) == nil)
        #expect(Self.decode(more) == nil)
        #expect(Self.decode(Data(data.prefix(63))) == nil)
    }

    /// `-` separates the fields of a name, so the escape of `-` keeps each name prefix unique.
    @Test func aDashInThePoolPathIsEscaped() {
        let paths = ["a-1.wav", "a.wav", "a1.wav", "a", "Take 1/a.wav"]
        let names = paths.map { PeakFile.name(path: $0, stamp: Self.stamp) }

        #expect(Set(names).count == paths.count)
        for (path, name) in zip(paths, names) {
            #expect(name.hasSuffix("-1036804096-1790293732-540000123.peaks"))
            #expect(!name.contains("/"))
            for other in paths where other != path {
                #expect(!name.hasPrefix(PeakFile.escape(other) + "-"), "\(name) against \(other)")
            }
        }
        #expect(names[0] == "a%2D1.wav-1036804096-1790293732-540000123.peaks")
    }

    @Test func aWriteThenAReadGivesThePeaks() async throws {
        let folder = try TemporaryFolder()
        let cache = folder.url.appending(path: "Peaks")
        let peaks = try await Self.peaks()

        try PeakFile.write(peaks, path: "a.wav", in: cache)

        #expect(
            try FileManager.default.contentsOfDirectory(atPath: cache.path) == [
                PeakFile.name(path: "a.wav", stamp: Self.stamp)
            ])
        #expect(PeakFile.read(path: "a.wav", stamp: Self.stamp, channels: 1, rate: 48_000, in: cache) == peaks)
        #expect(PeakFile.read(path: "b.wav", stamp: Self.stamp, channels: 1, rate: 48_000, in: cache) == nil)
    }

    /// A rename that fails (a folder holds the name) leaves no temporary file.
    @Test func aFailedWriteLeavesNoTemporaryFile() async throws {
        let folder = try TemporaryFolder()
        let cache = folder.url.appending(path: "Peaks")
        let peaks = try await Self.peaks()
        let blocker = cache.appending(path: PeakFile.name(path: "a.wav", stamp: Self.stamp))
        try FileManager.default.createDirectory(at: blocker.appending(path: "x"), withIntermediateDirectories: true)

        #expect(throws: POSIXError.self) { try PeakFile.write(peaks, path: "a.wav", in: cache) }

        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path) == [blocker.lastPathComponent])
    }
}
