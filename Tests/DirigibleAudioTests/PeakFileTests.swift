import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The peak cache file of decision 0017, version 2 (timeline-view criterion 2).
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

    /// `peaks` as a cache file of version 1, little-endian: "DIRPEAKS", the UInt32 fields version 1,
    /// 256 frames per bin, 3 levels, the channels, the rate, and 0, the Int64 stamp fields, the
    /// UInt64 frames, then a UInt16 peak and a UInt16 RMS for each bin, 65535 = 0 dBFS.
    static func version1(_ peaks: Peaks) -> Data {
        func short<Value: FixedWidthInteger>(_ value: Value) -> UInt16 {
            UInt16((Double(value) / Double(Value.max) * 65535).rounded()).littleEndian
        }
        var data = Data("DIRPEAKS".utf8)
        let fields: [UInt32] = [1, 256, 3, UInt32(peaks.channels), UInt32(peaks.sampleRate), 0]
        fields.map(\.littleEndian).withUnsafeBytes { data.append(contentsOf: $0) }
        let stamp = [peaks.stamp.size, Int64(peaks.stamp.seconds), Int64(peaks.stamp.nanoseconds)]
        stamp.map(\.littleEndian).withUnsafeBytes { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(peaks.frames.count).littleEndian) { data.append(contentsOf: $0) }
        let values = peaks.levels.flatMap { $0.flatMap { [short($0.peak), short($0.rms)] } }
        values.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// The name of a cache file of version 1: the escaped pool path, the size, the seconds, and
    /// the nanoseconds of the stamp, then `.peaks`.
    static func version1Name(_ escapedPath: String, _ stamp: FileStamp) -> String {
        "\(escapedPath)-\(stamp.size)-\(stamp.seconds)-\(stamp.nanoseconds).peaks"
    }

    /// Decision 0024 P5: a cache file of version 1 on the disk is a miss, and the write of
    /// version 2 goes to another name, so the file of a version 1 build stays as it is.
    @Test func aVersion1FileIsAMissAndStaysNextToVersion2() async throws {
        let folder = try TemporaryFolder()
        let cache = folder.url.appending(path: "Peaks")
        let peaks = try await Self.peaks()
        let old = Self.version1(peaks)
        let oldName = Self.version1Name("a.wav", Self.stamp)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try old.write(to: cache.appending(path: oldName))

        #expect(old.count == 64 + 4 * peaks.levels.map(\.count).reduce(0, +))
        #expect(Self.decode(old) == nil, "a version 1 file decodes")
        #expect(PeakFile.read(path: "a.wav", stamp: Self.stamp, channels: 1, rate: 48_000, in: cache) == nil)

        try PeakFile.write(peaks, path: "a.wav", in: cache)

        let newName = "a.wav-1036804096-1790293732-540000123.v2.peaks"
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).sorted() == [oldName, newName])
        #expect(try Data(contentsOf: cache.appending(path: oldName)) == old)
        #expect(PeakFile.read(path: "a.wav", stamp: Self.stamp, channels: 1, rate: 48_000, in: cache) == peaks)
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

            #expect(data.count == 64 + 8 * peaks.levels.map(\.count).reduce(0, +))
            #expect(PeakFile.decode(data, stamp: stamp, channels: channels, rate: 48_000) == peaks)
        }
    }

    /// Each row of the format table: change one field, and the reader refuses the file.
    @Test(arguments: [
        ("magic", 0, UInt64(0x5859_5A)),
        ("version", 8, UInt64(3)),
        ("binFrames", 12, UInt64(512)),
        ("levels", 16, UInt64(2)),
        ("binBytes", 28, UInt64(4)),
    ])
    func aChangedHeaderFieldIsRefused(field: String, offset: Int, value: UInt64) async throws {
        var data = PeakFile.encode(try await Self.peaks())
        #expect(Self.decode(data) != nil)

        withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian) {
            data.replaceSubrange(offset..<offset + 4, with: $0)
        }

        #expect(Self.decode(data) == nil, "\(field)")
    }

    /// Decision 0024 P1 and P9: the header starts with the magic "DIRPEAKS" and the UInt32
    /// version 2, little-endian, and holds the 8 bytes of a bin at offset 28.
    @Test func theWriterStampsVersion2() async throws {
        let data = PeakFile.encode(try await Self.peaks())
        #expect(data.prefix(12) == Data("DIRPEAKS".utf8) + Data([2, 0, 0, 0]))
        #expect(data[28..<32] == Data([8, 0, 0, 0]))
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

        #expect(Self.decode(data.dropLast(8)) == nil)
        #expect(Self.decode(data + Data(count: 8)) == nil)
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
            #expect(name.hasSuffix("-1036804096-1790293732-540000123.v2.peaks"))
            #expect(!name.contains("/"))
            for other in paths where other != path {
                #expect(!name.hasPrefix(PeakFile.escape(other) + "-"), "\(name) against \(other)")
            }
        }
        #expect(names[0] == "a%2D1.wav-1036804096-1790293732-540000123.v2.peaks")
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

    /// Sets the modification time of `url` to `days` days ago.
    static func age(_ url: URL, days: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path)
    }

    /// Code gate 1 item 2: a prune removes the cache files and the temporary files that were not
    /// used since the cutoff, and keeps the others.
    @Test func aPruneRemovesOnlyTheFilesUnusedSinceTheCutoff() async throws {
        let folder = try TemporaryFolder()
        let cache = folder.url.appending(path: "Peaks")
        let peaks = try await Self.peaks()
        try PeakFile.write(peaks, path: "old.wav", in: cache)
        try PeakFile.write(peaks, path: "used.wav", in: cache)
        let old = cache.appending(path: PeakFile.name(path: "old.wav", stamp: Self.stamp))
        let temporary = cache.appending(path: ".x.peaks.1.tmp")
        try Data([1]).write(to: temporary)
        try Self.age(old, days: 91)
        try Self.age(temporary, days: 91)
        try Self.age(cache.appending(path: PeakFile.name(path: "used.wav", stamp: Self.stamp)), days: 89)

        PeakFile.prune(cache, before: .now.addingTimeInterval(-90 * 86_400))

        #expect(
            try FileManager.default.contentsOfDirectory(atPath: cache.path) == [
                PeakFile.name(path: "used.wav", stamp: Self.stamp)
            ])
    }

    /// Code gate 1 item 2: a write keeps the cache file of the same pool path with another stamp.
    /// Pool paths repeat in each package (`take1-1-1.wav`), so that file can be the peaks of
    /// another package.
    @Test func aWriteKeepsTheSamePoolPathOfAnotherStamp() async throws {
        let folder = try TemporaryFolder()
        let cache = folder.url.appending(path: "Peaks")
        let peaks = try await Self.peaks()
        let other = FileStamp(size: 1, seconds: 2, nanoseconds: 3)
        let otherPeaks = try await {
            let package = try MixPackage()
            try package.addFile("a", channels: [ramp(frames: 70_000)])
            let file = try AVAudioFile(forReading: package.url.appending(path: "Clips/a.wav"))
            return try await computePeaks(file, stamp: other) { .go }
        }()

        try PeakFile.write(otherPeaks, path: "take1-1-1.wav", in: cache)
        try PeakFile.write(peaks, path: "take1-1-1.wav", in: cache)

        #expect(PeakFile.read(path: "take1-1-1.wav", stamp: other, channels: 1, rate: 48_000, in: cache) == otherPeaks)
        #expect(PeakFile.read(path: "take1-1-1.wav", stamp: Self.stamp, channels: 1, rate: 48_000, in: cache) == peaks)
    }

    /// A verify copy has its own cache, and the real ID and the command-line front end keep the
    /// folder of earlier versions.
    @Test func theFolderFollowsTheBundleID() {
        let caches = URL(filePath: "/Users/u/Library/Caches")
        #expect(
            PeakFile.folder(bundleID: "com.delineas.dirigible.verify-0123abcd", caches: caches).path
                == "/Users/u/Library/Caches/com.delineas.dirigible.verify-0123abcd/Peaks")
        #expect(
            PeakFile.folder(bundleID: "com.delineas.dirigible", caches: caches).path
                == "/Users/u/Library/Caches/com.delineas.dirigible/Peaks")
        #expect(PeakFile.folder.path == URL.cachesDirectory.path + "/com.delineas.dirigible/Peaks")
    }
}
