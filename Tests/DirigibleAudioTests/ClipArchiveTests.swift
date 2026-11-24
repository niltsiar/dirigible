import AVFoundation
import CryptoKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// One clip conversion, WAV to FLAC and back (decision 0072, run criteria C1 and C10).
struct ClipArchiveTests {
    @Test(arguments: [(1, 44_100), (2, 44_100), (1, 48_000), (2, 48_000)])
    func aRoundTripKeepsEverySample(channels: Int, rate: Int) throws {
        let clip = try ArchiveClip(channels: channels, rate: rate)
        let before = try wavData(clip.wav)
        #expect(firstCodes(before, channels: channels) == ArchiveClip.codes, "the fixture holds the edge codes")

        #expect(try archiveClip(clip.file, in: clip.package, rate: rate))
        let info = try streamInfo(clip.flac)
        #expect(info.bits == 24)
        #expect(info.frames == ArchiveClip.frames)
        #expect(info.md5 == Data(Insecure.MD5.hash(data: before)), "the STREAMINFO MD5 is the MD5 of the WAV data")
        #expect(try clip.names() == ["a.flac"])

        #expect(try unarchiveClip(clip.file, in: clip.package, rate: rate))
        #expect(try wavData(clip.wav) == before, "the data bytes after the round trip")
        #expect(try clip.names() == ["a.wav"])
    }

    @Test func aFlippedByteInTheEncodedFileGivesAMismatchAndKeepsTheWAV() throws {
        let clip = try ArchiveClip(channels: 2, rate: 48_000)
        let before = try Data(contentsOf: clip.wav)
        var flipped = false

        #expect(throws: ClipArchiveFault.mismatch(path: "a.wav")) {
            try archiveClip(
                clip.file, in: clip.package, rate: 48_000,
                after: { step, temporary in
                    if step == .encoded { flipped = (try? flipByte(in: temporary)) != nil }
                    return true
                })
        }
        #expect(flipped)
        #expect(try Data(contentsOf: clip.wav) == before)
        #expect(try clip.names() == ["a.wav"], "no FLAC and no temporary file")
    }

    @Test func a16BitWAVStaysAndA24BitWAVConverts() throws {
        let clip = try ArchiveClip(channels: 1, rate: 48_000)
        let sixteen = clip.clips.appending(path: "b.wav")
        do {
            let file = try AVAudioFile(
                forWriting: sixteen,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                    AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                ])
            try file.write(from: clip.buffer)
        }
        let before = try Data(contentsOf: sixteen)
        let file = AudioFile(id: "f2", path: "b.wav", layout: .mono, length: Frames(ArchiveClip.frames))

        #expect(throws: ClipArchiveFault.notArchivable(path: "b.wav")) {
            try archiveClip(file, in: clip.package, rate: 48_000)
        }
        #expect(try Data(contentsOf: sixteen) == before)
        #expect(try archiveClip(clip.file, in: clip.package, rate: 48_000))
        #expect(try clip.names() == ["a.flac", "b.wav"])
    }

    @Test func aFileAtTheFLACNameWithOtherAudioGivesNameTaken() throws {
        let clip = try ArchiveClip(channels: 1, rate: 48_000, seed: 1)
        let other = try ArchiveClip(channels: 1, rate: 48_000, seed: 2)
        #expect(try archiveClip(other.file, in: other.package, rate: 48_000))
        try FileManager.default.copyItem(at: other.flac, to: clip.flac)
        let (wav, flac) = (try Data(contentsOf: clip.wav), try Data(contentsOf: clip.flac))

        #expect(throws: ClipArchiveFault.nameTaken(path: "a.flac")) {
            try archiveClip(clip.file, in: clip.package, rate: 48_000)
        }
        #expect(try Data(contentsOf: clip.wav) == wav)
        #expect(try Data(contentsOf: clip.flac) == flac)
        #expect(try clip.names() == ["a.flac", "a.wav"])
    }

    @Test func withBothFilesEachDirectionChecksTheOtherFileAndRemovesTheSource() throws {
        let clip = try ArchiveClip(channels: 2, rate: 48_000)
        let wav = try Data(contentsOf: clip.wav)
        #expect(try archiveClip(clip.file, in: clip.package, rate: 48_000))
        let flac = try Data(contentsOf: clip.flac)

        try wav.write(to: clip.wav)
        #expect(try archiveClip(clip.file, in: clip.package, rate: 48_000))
        #expect(try clip.names() == ["a.flac"])
        #expect(try Data(contentsOf: clip.flac) == flac)

        #expect(try unarchiveClip(clip.file, in: clip.package, rate: 48_000))
        let restored = try Data(contentsOf: clip.wav)
        try flac.write(to: clip.flac)
        #expect(try unarchiveClip(clip.file, in: clip.package, rate: 48_000))
        #expect(try clip.names() == ["a.wav"])
        #expect(try Data(contentsOf: clip.wav) == restored)
    }

    @Test func aStopKeepsTheSourceAndLeavesNoTemporaryFile() throws {
        let clip = try ArchiveClip(channels: 2, rate: 48_000)
        let wav = try Data(contentsOf: clip.wav)
        var checks = 0
        func secondCheck() -> Bool {
            checks += 1
            return checks > 1
        }

        #expect(try !archiveClip(clip.file, in: clip.package, rate: 48_000, isCancelled: secondCheck))
        #expect(checks == 2, "the second block check stops the encode")
        #expect(try Data(contentsOf: clip.wav) == wav)
        #expect(try clip.names() == ["a.wav"])

        #expect(try archiveClip(clip.file, in: clip.package, rate: 48_000))
        let flac = try Data(contentsOf: clip.flac)
        checks = 0
        #expect(try !unarchiveClip(clip.file, in: clip.package, rate: 48_000, isCancelled: secondCheck))
        #expect(checks == 2, "the second block check stops the decode")
        #expect(try Data(contentsOf: clip.flac) == flac)
        #expect(try clip.names() == ["a.flac"])
    }

    @Test func theNameRules() {
        let uuid = UUID()
        #expect(archivedPath(of: "take1-1-1.wav") == "take1-1-1.flac")
        #expect(archivedPath(of: "Imports/Intro.WAV") == "Imports/Intro.flac")
        #expect(archivedPath(of: "take1-1-1.flac") == nil)
        #expect(archivedPath(of: "music.m4a") == nil)
        #expect(archiveTemporaryName(of: "a.flac", uuid) == ".a.flac.archive-\(uuid.uuidString).tmp")
        #expect(isArchiveTemporary(archiveTemporaryName(of: "a.flac", uuid)))
        #expect(isArchiveTemporary(archiveTemporaryName(of: "a.wav", uuid)))
        #expect(!isArchiveTemporary("a.flac.archive-\(uuid.uuidString).tmp"), "no leading dot")
        #expect(!isArchiveTemporary(".a.flac.archive-1.tmp"), "no UUID")
        #expect(!isArchiveTemporary(temporaryWAV(of: "a")))
    }
}

/// A package with one 24-bit clip WAV `Clips/a.wav` from the clip writer: the codes -8388608,
/// -1, 0, 1, 8388607 at the start of each channel, then seeded noise. 100,003 frames are two
/// blocks of the conversion.
struct ArchiveClip {
    static let codes: [Int32] = [-8_388_608, -1, 0, 1, 8_388_607]
    static let frames = 100_003

    let folder: TemporaryFolder
    let package: URL
    let file: AudioFile
    let buffer: AVAudioPCMBuffer

    var clips: URL { package.appending(path: clipsFolderName) }
    var wav: URL { clips.appending(path: "a.wav") }
    var flac: URL { clips.appending(path: "a.flac") }

    init(channels: Int, rate: Int, seed: UInt64 = 0) throws {
        folder = try TemporaryFolder()
        package = folder.url.appending(path: "Archive.dirigible")
        try FileManager.default.createDirectory(
            at: package.appending(path: clipsFolderName), withIntermediateDirectories: true)
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(channels)))
        buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.frames)))
        buffer.frameLength = AVAudioFrameCount(Self.frames)
        var state = seed &+ UInt64(channels * rate)
        for channel in 0..<channels {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Self.frames {
                let code: Int32
                if frame < Self.codes.count {
                    code = Self.codes[frame]
                } else {
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    code = Int32(truncatingIfNeeded: state >> 40) - 8_388_608
                }
                samples[frame] = Float(code) / 8_388_608
            }
        }
        let writer = try ClipWriter(
            url: package.appending(path: "\(clipsFolderName)/a.wav"), file: "a.wav", format: format)
        try writer.write(buffer)
        try writer.close()
        file = AudioFile(
            id: "f1", path: "a.wav", layout: try #require(ChannelLayout(channelCount: channels)),
            length: Frames(Self.frames))
    }

    /// The names in `Clips/`, sorted.
    func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: clips.path).sorted() }
}

/// The bytes of the `data` chunk of a RIFF WAV.
func wavData(_ url: URL) throws -> Data {
    let bytes = try Data(contentsOf: url)
    var offset = 12
    while offset + 8 <= bytes.count {
        let size = Int(bytes[offset + 4..<offset + 8].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        if bytes[offset..<offset + 4] == Data("data".utf8) { return bytes[offset + 8..<offset + 8 + size] }
        offset += 8 + size + size % 2
    }
    throw CocoaError(.fileReadCorruptFile)
}

/// The first codes of channel 0 of packed 24-bit little-endian WAV data.
func firstCodes(_ data: Data, channels: Int) -> [Int32] {
    (0..<ArchiveClip.codes.count).map { frame in
        let start = data.startIndex + frame * 3 * channels
        let value = Int32(data[start]) | Int32(data[start + 1]) << 8 | Int32(data[start + 2]) << 16
        return (value << 8) >> 8
    }
}

/// The bits per sample, the frame count, and the MD5 of the STREAMINFO block of a FLAC file
/// (RFC 9639 section 8.2): "fLaC", a 4-byte block header, then the 34 bytes of STREAMINFO.
func streamInfo(_ url: URL) throws -> (bits: Int, frames: Int, md5: Data) {
    let bytes = [UInt8](try Data(contentsOf: url).prefix(42))
    guard bytes.count == 42, bytes[0..<4] == [0x66, 0x4C, 0x61, 0x43], bytes[4] & 0x7F == 0 else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let info = Array(bytes[8...])
    let bits = (Int(info[12] & 0x01) << 4 | Int(info[13] >> 4)) + 1
    let frames = info[14..<18].reduce(Int(info[13] & 0x0F)) { $0 << 8 | Int($1) }
    return (bits, frames, Data(info[18..<34]))
}

/// Flips one byte in the middle of the audio frames of a file.
func flipByte(in url: URL) throws {
    var bytes = try Data(contentsOf: url)
    bytes[bytes.count / 2] ^= 0xFF
    try bytes.write(to: url)
}
