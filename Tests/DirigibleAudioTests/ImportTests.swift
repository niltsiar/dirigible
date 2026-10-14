import AVFoundation
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// The file import (decision 0040): the conversion, the name, and the session edits.
struct ImportTests {
    @Test func aStereoFileImportsIntoAMonoTrackAtTheSessionRate() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Interview.wav")
        try writeSource(
            source, .wav16, rate: 44_100, channels: [impulse(88_200, at: 22_050), impulse(88_200, at: 22_050)])

        let (session, clip) = try importAudio(
            source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url, level: false)

        #expect(package.clipsNames == ["Interview.wav"], "Clips/ holds the WAV and no temporary file")
        #expect(clip == "Interview")
        let wav = try ImportedWAV(package.clip("Interview.wav"))
        #expect(wav.rate == 48_000 && wav.bits == 24 && wav.channels.count == 1, "a mono 24-bit WAV at 48 kHz")
        #expect(abs(wav.frames - 96_000) <= 1, "the length at 48 kHz")
        #expect(abs(wav.peakFrame - 24_000) <= 1, "the impulse at 0.5 s")
        #expect(session.clip(clip)?.track == "t1")
        #expect(session.files["Interview"]?.length == Frames(wav.frames))
    }

    /// C1: the AIFF is 96 kHz mono; the others are 44.1 kHz stereo. MP3 and M4A are lossy, so the
    /// impulse gets 1 ms (U14b).
    @Test(arguments: [SourceFormat.wav16, .aiff24, .flac, .mp3, .m4a])
    func everyFormatImportsAtTheSessionRate(format: SourceFormat) throws {
        let package = try ImportPackage()
        let (rate, channels) = format == .aiff24 ? (96_000, 1) : (44_100, 2)
        let source = package.source("Source.\(format.fileExtension)")
        try writeSource(
            source, format, rate: rate, channels: Array(repeating: impulse(rate * 2, at: rate / 2), count: channels))
        let decoded = try AVAudioFile(forReading: source)
        #expect(decoded.fileFormat.sampleRate == Double(rate), "AVAudioFile opens the source (U14)")

        let (session, clip) = try importAudio(
            source, to: ImportTarget(track: nil, start: 0), of: package.session, in: package.url, level: false)

        let wav = try ImportedWAV(package.clip("Source.wav"))
        #expect(wav.rate == 48_000 && wav.bits == 24 && wav.channels.count == channels, "a 24-bit WAV at 48 kHz")
        let expected = Int((Double(decoded.length) * 48_000 / Double(rate)).rounded())
        #expect(abs(wav.frames - expected) <= 1, "the length at 48 kHz")
        let tolerance = format == .mp3 || format == .m4a ? 48 : 1
        #expect(abs(wav.peakFrame - 24_000) <= tolerance, "the impulse at 0.5 s")
        #expect(session.clip(clip)?.clip.length == Frames(wav.frames))
    }

    @Test func aSameRate24BitWAVImportsBitForBit() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Same.wav")
        let samples = ramp(frames: 100_000)
        try writeSource(source, .wav24, rate: 48_000, channels: [samples])

        _ = try importAudio(
            source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url, level: false)

        let wav = try ImportedWAV(package.clip("Same.wav"))
        #expect(wav.channels == [samples], "each sample is equal")
    }

    /// C7: the track layout wins. 2 into 1 is 0.5 L + 0.5 R; 1 into 2 goes to both channels.
    @Test func theTrackLayoutWins() throws {
        let package = try ImportPackage(tracks: [("mono", .mono), ("stereo", .stereo)])
        let (left, right) = (ramp(frames: 70_000), ramp(frames: 70_000, channel: 1))
        try writeSource(package.source("Two.wav"), .wav24, rate: 48_000, channels: [left, right])
        try writeSource(package.source("One.wav"), .wav24, rate: 48_000, channels: [left])

        let first = try importAudio(
            package.source("Two.wav"), to: ImportTarget(track: "mono", start: 0), of: package.session,
            in: package.url, level: false)
        _ = try importAudio(
            package.source("One.wav"), to: ImportTarget(track: "stereo", start: 0), of: first.session,
            in: package.url, level: false)

        let mixed = try ImportedWAV(package.clip("Two.wav"))
        let mix = zip(left, right).map { 0.5 * ($0 + $1) }
        #expect(mixed.channels.count == 1 && maxError(mixed.channels[0], mix) <= 0x1p-23, "0.5 L + 0.5 R")
        let copied = try ImportedWAV(package.clip("One.wav"))
        #expect(copied.channels == [left, left], "the channel goes to both")
    }

    @Test func noTrackGivesANewLastTrackWithTheFileLayout() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Guest.wav")
        try writeSource(source, .wav16, rate: 48_000, channels: [ramp(frames: 4_800), ramp(frames: 4_800)])

        let (session, clip) = try importAudio(
            source, to: ImportTarget(track: nil, start: 9_600), of: package.session, in: package.url, level: false)

        let track = try #require(session.tracks.last)
        #expect(session.tracks.count == 2 && track.name == "Guest" && track.layout == .stereo)
        #expect(session.clip(clip)?.track == track.id && session.clip(clip)?.clip.start == 9_600)
    }

    @Test func theImportedClipIsLeveled() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Voice.wav")
        try writeSource(source, .wav24, rate: 48_000, channels: [sine(seconds: 3, rate: 48_000)])

        let (session, clip) = try importAudio(
            source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url)

        let leveled = try #require(session.clip(clip)?.clip)
        var unleveled = leveled
        unleveled.gain = .zero
        let measured = try #require(try clipLoudness(unleveled, in: session, package: package.url).loudness.integrated)
        let expected = clipTarget(.mono) - measured.value
        #expect(abs(leveled.gain.dB - expected) < 0.1, "the gain is the target minus the loudness")
    }

    /// C4a: with no level, and for silence, the clip keeps the gain of the conversion: 0 dB, or the
    /// A11 gain of a peak over full scale.
    @Test func aSilentOrUnleveledImportKeepsTheConversionGain() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        try writeSource(
            package.source("Silence.wav"), .wav16, rate: 48_000, channels: [[Float](repeating: 0, count: 48_000)])
        try writeSource(package.source("Loud.wav"), .wav16, rate: 44_100, channels: [loudTail(frames: 132_300)])

        let silent = try importAudio(
            package.source("Silence.wav"), to: ImportTarget(track: "t1", start: 0), of: package.session,
            in: package.url)
        let loud = try importAudio(
            package.source("Loud.wav"), to: ImportTarget(track: "t1", start: 96_000), of: silent.session,
            in: package.url, level: false)

        #expect(loud.session.clip(silent.clip)?.clip.gain == .zero, "silence keeps 0 dB")
        let gain = try #require(loud.session.clip(loud.clip)?.clip.gain)
        let wav = try ImportedWAV(package.clip("Loud.wav"))
        let peak = wav.channels[0].map(abs).max() ?? 0
        #expect(gain.dB > 0.1 && peak < 1, "the A11 gain gives back the level of the scaled WAV")
    }

    @Test func aUsedNameGetsANumber() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Interview.wav")
        try writeSource(source, .wav16, rate: 48_000, channels: [ramp(frames: 4_800)])
        try FileManager.default.createDirectory(at: package.clip(""), withIntermediateDirectories: true)
        try Data().write(to: package.clip("interview 2.wav"))

        let first = try importAudio(
            source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url, level: false)
        let second = try importAudio(
            source, to: ImportTarget(track: "t1", start: 9_600), of: first.session, in: package.url, level: false)

        #expect(first.clip == "Interview" && second.clip == "Interview 3", "a pool name and a Clips/ name are used")
        #expect(second.session.files["Interview 3"]?.path == "Interview 3.wav")
        let session = Session(sampleRate: 48_000)
        #expect(importStem(of: URL(filePath: "/x/.a:b.mp3"), in: session, package: package.url) == "ab")
        #expect(importStem(of: URL(filePath: "/x/\u{1}.wav"), in: session, package: package.url) == "Imported")
    }

    /// Code gate 1 items 2 and 3: a stem never takes the name of a capture segment, and it has no
    /// character that exFAT refuses.
    @Test func aStemAvoidsCaptureNamesAndExFATCharacters() throws {
        let package = try ImportPackage()
        let capture = package.url.appending(path: captureFolderName)
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        try Data().write(to: capture.appending(path: "take1-1-1.caf"))
        let session = Session(sampleRate: 48_000)

        #expect(
            importStem(of: URL(filePath: "/x/take1-1-1.wav"), in: session, package: package.url) == "take1-1-1 2",
            "a capture segment name is used")
        #expect(
            importStem(of: URL(filePath: "/x/a?b*c<d>e|f\"g\\h.mp3"), in: session, package: package.url)
                == "abcdefgh", "exFAT characters go")
    }

    @Test func aLoudTailProgressesWithNoStepBack() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        try writeSource(package.source("Tail.wav"), .wav16, rate: 44_100, channels: [loudTail(frames: 3 * 65_536)])
        let box = OSAllocatedUnfairLock(initialState: [Double]())

        let (session, clip) = try importAudio(
            package.source("Tail.wav"), to: ImportTarget(track: "t1", start: 0), of: package.session,
            in: package.url, level: false, progress: { value in box.withLock { $0.append(value) } })
        let values = box.withLock { $0 }

        #expect(session.clip(clip)?.clip.gain != .zero, "two passes")
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "progress never goes down: \(values)")
        #expect(values.contains { $0 > 0.5 && $0 < 1 } && values.last == 1, "pass 2 maps to 0.5...1: \(values)")
    }

    /// Code gate 1 item 8: the second pass (A11) on a compressed source keeps the length of the
    /// first pass, and no sample saturates.
    @Test(arguments: [SourceFormat.m4a, .mp3])
    func aLoudCompressedFileConvertsInTwoPasses(format: SourceFormat) throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Loud.\(format.fileExtension)")
        try writeSource(source, format, rate: 44_100, channels: [loudTail(frames: 3 * 65_536)])
        let decoded = try AVAudioFile(forReading: source).length

        let (session, clip) = try importAudio(
            source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url, level: false)

        #expect(try #require(session.clip(clip)?.clip.gain.dB) > 0.1, "two passes")
        let wav = try ImportedWAV(package.clip("Loud.wav"))
        let expected = Int((Double(decoded) * 48_000 / 44_100).rounded())
        #expect(abs(wav.frames - expected) <= 1, "the length of pass 1")
        #expect((wav.channels[0].map(abs).max() ?? 1) < 1, "no sample saturates")
    }

    @Test func aQuietFileProgressesFromHalfToOne() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        try writeSource(package.source("Quiet.wav"), .wav16, rate: 44_100, channels: [sine(seconds: 3, rate: 44_100)])
        let box = OSAllocatedUnfairLock(initialState: [Double]())

        _ = try importAudio(
            package.source("Quiet.wav"), to: ImportTarget(track: "t1", start: 0), of: package.session,
            in: package.url, level: false, progress: { value in box.withLock { $0.append(value) } })
        let values = box.withLock { $0 }

        #expect(values.dropLast().allSatisfy { $0 <= 0.5 } && values.last == 1, "one pass ends at 1: \(values)")
    }
}

/// `importAudio` with a free space that always passes, for the tests that do not check the disk.
func importAudio(
    _ source: URL, to target: ImportTarget, of session: Session, in package: URL, level: Bool = true,
    progress: @escaping @Sendable (Double) -> Void = { _ in }, isCancelled: @escaping @Sendable () -> Bool = { false }
) throws(ImportError) -> (session: Session, clip: ClipID) {
    try DirigibleAudio.importAudio(
        source, to: target, of: session, in: package, level: level, freeBytes: { .max }, progress: progress,
        isCancelled: isCancelled)
}

/// A package folder with a session and no `session.xml`: the import writes only `Clips/`.
final class ImportPackage {
    let folder: TemporaryFolder
    let url: URL
    var session: Session

    init(rate: Int = 48_000, tracks: [(TrackID, ChannelLayout)] = []) throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        session = Session(sampleRate: rate)
        for (id, layout) in tracks { try session.addTrack(id, name: id.rawValue, layout: layout) }
    }

    /// A path for a source file, outside the package.
    func source(_ name: String) -> URL { folder.url.appending(path: name) }
    func clip(_ name: String) -> URL { url.appending(path: "\(clipsFolderName)/\(name)") }
    /// The names in `Clips/`, also hidden ones, sorted.
    var clipsNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.appending(path: clipsFolderName).path)) ?? [])
            .sorted()
    }
}

enum SourceFormat {
    case wav16, wav24, wavFloat, aiff24, flac, m4a, mp3

    var fileExtension: String {
        switch self {
        case .wav16, .wav24, .wavFloat: "wav"
        case .aiff24: "aif"
        case .flac: "flac"
        case .m4a: "m4a"
        case .mp3: "mp3"
        }
    }
}

/// Silence of `frames` frames with one sample of 0.5 at `frame`.
func impulse(_ frames: Int, at frame: Int) -> [Float] {
    var samples = [Float](repeating: 0, count: frames)
    samples[frame] = 0.5
    return samples
}

/// Writes `channels` (one array for each channel) at `rate` Hz to `url` in `format`. WAV and
/// AIFF go through `AVAudioFile`; FLAC, M4A (AAC 192 kbit/s), and MP3 (LAME 192 kbit/s, with
/// its tag) go through the export writer.
func writeSource(_ url: URL, _ format: SourceFormat, rate: Int, channels: [[Float]]) throws {
    let client = try #require(
        AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(channels.count)))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: client, frameCapacity: AVAudioFrameCount(channels[0].count)))
    buffer.frameLength = AVAudioFrameCount(channels[0].count)
    for (index, samples) in channels.enumerated() {
        buffer.floatChannelData![index].update(from: samples, count: samples.count)
    }
    func pcm(bits: Int, bigEndian: Bool, float: Bool = false) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels.count,
                AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: float, AVLinearPCMIsBigEndianKey: bigEndian,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
    let exported: ExportFormat
    switch format {
    case .wav16: return try pcm(bits: 16, bigEndian: false)
    case .wav24: return try pcm(bits: 24, bigEndian: false)
    case .wavFloat: return try pcm(bits: 32, bigEndian: false, float: true)
    case .aiff24: return try pcm(bits: 24, bigEndian: true)
    case .flac: exported = .flac(.bits16)
    case .m4a: exported = .aac(.k192)
    case .mp3: exported = .mp3(.k192)
    }
    // The MP3 writer opens a file that exists.
    FileManager.default.createFile(atPath: url.path, contents: nil)
    try writeFile(url, format: exported, rate: rate, client: client) { write throws(ExportError) in try write(buffer) }
}

/// Silence with a full-scale square wave in the last 10,000 frames: the converter takes its peak
/// over 1, so the import makes a second pass, which it knows only at the end of the first (A11).
func loudTail(frames: Int) -> [Float] {
    (0..<frames).map { $0 < frames - 10_000 ? 0 : ($0 / 50) % 2 == 0 ? 1 : -1 }
}

/// The facts of an imported WAV.
struct ImportedWAV {
    let rate: Double
    let bits: Int?
    let channels: [[Float]]
    var frames: Int { channels[0].count }
    /// The frame of the largest sample of channel 1.
    var peakFrame: Int { channels[0].indices.max { abs(channels[0][$0]) < abs(channels[0][$1]) } ?? -1 }

    init(_ url: URL) throws {
        let (rate, bits, samples) = try readAudio(url)
        let count = Int(try AVAudioFile(forReading: url).fileFormat.channelCount)
        self.rate = rate
        self.bits = bits
        channels = (0..<count).map { channel in stride(from: channel, to: samples.count, by: count).map { samples[$0] }
        }
    }
}
