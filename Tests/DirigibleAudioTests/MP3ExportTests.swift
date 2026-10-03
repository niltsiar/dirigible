import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// MP3 export through LAME (MP3 run criteria 6 to 12 and 17, decision 0034). Tolerances: a
/// length exact (the LAME tag gives the delay and the padding); a level ± 0.1 dB for a 997 Hz
/// sine; a file size ± 3 %.
struct MP3ExportTests {
    /// A 997 Hz sine at `rms` dBFS RMS.
    static func sine(seconds: Double, rms: Double = -20, rate: Int = 48_000) -> [Float] {
        let amplitude = 2.0.squareRoot() * pow(10, rms / 20)
        let frames = Int(seconds * Double(rate))
        return (0..<frames).map { Float(amplitude * sin(2 * Double.pi * 997 * Double($0) / Double(rate))) }
    }

    static func mp3(_ bitRate: BitRate = .k128, _ layout: ChannelLayout = .stereo, _ rate: ExportRate = .session)
        -> ExportOptions
    { ExportOptions(format: .mp3(bitRate), layout: layout, rate: rate) }

    static func size(_ url: URL) throws -> Int {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    }

    /// The package folder holds only the package: no export file and no temporary file.
    static func expectNoOutput(_ package: MixPackage, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: package.folder.url.path)
        #expect(names == ["Mix.dirigible"], "left: \(names)", sourceLocation: sourceLocation)
    }

    @Test func aStereoMP3HasTheFactsAndTheExactLength() throws {
        let package = try ExportTests.package([Self.sine(seconds: 4)])

        let url = try ExportTests.export(package, 0..<192_000, Self.mp3(), to: "mix.mp3")
        let out = try ExportTests.read(url)

        #expect(out.format.mFormatID == kAudioFormatMPEGLayer3)
        #expect(out.format.mChannelsPerFrame == 2, "stereo MP3 has \(out.format.mChannelsPerFrame) channels")
        #expect(out.rate == 48_000)
        #expect(out.length == 192_000, "the MP3 length is \(out.length), not 192000")
        // The first frame is the LAME tag: "Info" after the 4-byte header and the 32-byte side
        // information of a stereo MPEG-1 frame, then the flags and the count of the 168 audio frames.
        let bytes = try #require(FileManager.default.contents(atPath: url.path))
        let frames = bytes[44..<48].reduce(0) { $0 << 8 | Int($1) }
        #expect(bytes[36..<40] == Data("Info".utf8) && frames == 168, "the first frame is no LAME tag of 168 frames")
    }

    @Test func aMonoMP3At44kHzHasTheFactsAndTheExactLength() throws {
        let package = try ExportTests.package([Self.sine(seconds: 4)])

        let out = try ExportTests.read(
            ExportTests.export(package, 0..<192_000, Self.mp3(.k128, .mono, .hz44100), to: "mix.mp3"))

        #expect(out.format.mFormatID == kAudioFormatMPEGLayer3)
        #expect(out.format.mChannelsPerFrame == 1, "mono MP3 has \(out.format.mChannelsPerFrame) channels")
        #expect(out.rate == 44_100)
        #expect(out.length == 176_400, "the MP3 length is \(out.length), not 176400")
    }

    /// At 44.1 kHz with 96 or 160 kbit/s, Core Audio often counts the LAME tag frame as audio: it
    /// reads one frame (1152 samples) more. The file is correct: its tag gives 176400 samples, and
    /// ffmpeg and mpg123 decode 176400 (probe len96). The test takes both lengths, so a change of
    /// Core Audio does not fail it, and any other length does.
    @Test func a96kbitMP3At44kHzHasTheTagLengthOrOneFrameMore() throws {
        let package = try ExportTests.package([Self.sine(seconds: 4)])

        let out = try ExportTests.read(
            ExportTests.export(package, 0..<192_000, Self.mp3(.k96, .mono, .hz44100), to: "mix.mp3"))

        #expect([176_400, 176_400 + 1152].contains(out.length), "Core Audio reads \(out.length)")
    }

    @Test func a32kHzSessionGivesA32kHzMP3() throws {
        let package = try ExportTests.package([Self.sine(seconds: 4, rate: 32_000)], rate: 32_000)

        let out = try ExportTests.read(ExportTests.export(package, 0..<128_000, Self.mp3(), to: "mix.mp3"))

        #expect(out.rate == 32_000)
        #expect(out.length == 128_000, "the MP3 length is \(out.length), not 128000")
    }

    /// CBR: 10 s at `bitRate` is `bitRate x 10 / 8` bytes.
    @Test(arguments: [BitRate.k64, .k256])
    func theMP3BitRateApplies(bitRate: BitRate) throws {
        let frames = 480_000
        let package = try ExportTests.package([
            ExportTests.noise(frames: frames, seed: 5), ExportTests.noise(frames: frames, seed: 6),
        ])

        let url = try ExportTests.export(package, 0..<Frames(frames), Self.mp3(bitRate), to: "mix.mp3")

        let expected = Double(bitRate.rawValue * 1000 * 10 / 8)
        let size = try Self.size(url)
        #expect(
            abs(Double(size) / expected - 1) <= 0.03, "\(size) bytes at \(bitRate.rawValue) kbit/s, not \(expected)")
    }

    /// LAME scales its input against clipping (probe U4): 0.45 dB lower at 128 kbit/s, equal at
    /// 256.
    @Test(arguments: [(BitRate.k128, -0.45), (.k256, 0.0)])
    func theMP3LevelFollowsTheLAMEScale(bitRate: BitRate, offset: Double) throws {
        let package = try ExportTests.package([Self.sine(seconds: 10)])

        let out = try ExportTests.read(ExportTests.export(package, 0..<480_000, Self.mp3(bitRate), to: "mix.mp3"))

        for channel in out.channels {
            let level = ExportTests.rmsDB(channel)
            #expect(abs(level - (-20 + offset)) <= 0.1, "\(level) dB at \(bitRate.rawValue) kbit/s")
        }
    }

    /// LAME would write 48 kHz with no error (probe U3).
    @Test func a96kHzSessionIsRefused() throws {
        let package = try ExportTests.package([Self.sine(seconds: 1, rate: 96_000)], rate: 96_000)

        #expect(throws: ExportError.rateNotSupported(96_000), "96000 Hz MP3 is refused") {
            try ExportTests.export(package, 0..<96_000, Self.mp3(), to: "mix.mp3")
        }
        try Self.expectNoOutput(package)
    }

    /// At 22.05 kHz LAME keeps 128 kbit/s, and lowers 256 kbit/s to 160 with no error (probe U7).
    @Test(arguments: [BitRate.k128, .k256])
    func a22kHzSessionIsRefused(bitRate: BitRate) throws {
        let package = try ExportTests.package([Self.sine(seconds: 1, rate: 22_050)], rate: 22_050)

        #expect(throws: ExportError.rateNotSupported(22_050), "22050 Hz MP3 at \(bitRate.rawValue) is refused") {
            try ExportTests.export(package, 0..<22_050, Self.mp3(bitRate), to: "mix.mp3")
        }
        try Self.expectNoOutput(package)
    }

    @Test func a96kHzSessionExportsAt48kHz() throws {
        let package = try ExportTests.package([Self.sine(seconds: 2, rate: 96_000)], rate: 96_000)

        let out = try ExportTests.read(
            ExportTests.export(package, 0..<192_000, Self.mp3(.k128, .stereo, .hz48000), to: "mix.mp3"))

        #expect(out.rate == 48_000)
        #expect(out.length == 96_000, "the MP3 length is \(out.length), not 96000")
    }

    /// No dither: one mix gives the same bytes twice on one machine.
    @Test func twoMP3ExportsAreByteIdentical() throws {
        let frames = 192_000
        let package = try ExportTests.package([
            ExportTests.noise(frames: frames, seed: 7), ExportTests.noise(frames: frames, seed: 8),
        ])

        let first = try ExportTests.export(package, 0..<Frames(frames), Self.mp3(), to: "a.mp3")
        let second = try ExportTests.export(package, 0..<Frames(frames), Self.mp3(), to: "b.mp3")

        #expect(try Data(contentsOf: first) == Data(contentsOf: second), "two MP3 exports differ")
    }

    /// The report measures before the encoder (decision 0032); the decoded file reads 0.45 LU
    /// lower at 128 kbit/s (probe U4).
    @Test func anMP3PodcastExportReportsTheLoudnessBeforeTheEncoder() throws {
        let options = ExportOptions(format: .mp3(.k128), layout: .stereo, rate: .session, loudness: .podcast)

        let export = try ExportLoudnessTests.export(tone([(20, -30)]), options, to: "mix.mp3")

        let report = try #require(export.result.loudness)
        let output = try #require(report.output).value
        #expect(abs(output - -16) <= 0.1, "the report says \(output) LUFS")
        let loudness = try measure(ExportTests.read(export.url).channels)
        let decoded = try #require(loudness.integrated).value
        #expect(abs(decoded - -16.45) <= 0.2, "the decoded MP3 reads \(decoded) LUFS")
    }

    @Test func aCancelAtTheFirstChunkLeavesNoMP3() throws {
        let package = try ExportTests.package([Self.sine(seconds: 4)])
        let source = try #require(ExportSource(range: 0..<192_000))
        let url = package.folder.url.appending(path: "mix.mp3")

        #expect(throws: ExportError.cancelled) {
            try exportMix(
                package.session, source: source, options: Self.mp3(), to: url, package: { package.url },
                isCancelled: { true })
        }
        try Self.expectNoOutput(package)
    }

    /// LAME aborts on an assert for a non-finite or very large sample (probe U8). The writer
    /// clamps each sample to ±64 and sets a non-finite sample to 0. One test for each case, so a
    /// control that aborts the process can run each case alone.
    @Test func aMixWithOneNaNExportsToMP3() throws {
        var samples = Self.sine(seconds: 4)
        samples[24_000] = .nan
        try Self.expectExactMP3(of: samples)
    }

    @Test func aHeldInfiniteMixExportsToMP3() throws {
        try Self.expectExactMP3(of: [Float](repeating: .infinity, count: 192_000))
    }

    @Test func aHeld1e30MixExportsToMP3() throws {
        try Self.expectExactMP3(of: [Float](repeating: 1e30, count: 192_000))
    }

    /// A value over the clamp limit becomes the limit, not 0: a held 100 encodes as a loud DC
    /// step, so the decoded file has more than silence.
    @Test func aHeld100MixIsClampedNotSilenced() throws {
        let package = try MixPackage()
        try Self.addFloatFile(package, "f1", [Float](repeating: 100, count: 192_000))
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 192_000)

        let out = try ExportTests.read(ExportTests.export(package, 0..<192_000, Self.mp3(), to: "mix.mp3"))

        let peak = ExportTests.peak(out.channels[0])
        #expect(peak > 0.5, "a held 100 decodes with a peak of \(peak)")
    }

    /// Exports 4 s of `samples` to MP3 and expects the exact length. The pool file is a float
    /// CAF, so the mix holds each value.
    static func expectExactMP3(of samples: [Float], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let package = try MixPackage()
        try addFloatFile(package, "f1", samples)
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 192_000)

        let out = try ExportTests.read(ExportTests.export(package, 0..<192_000, mp3(), to: "mix.mp3"))

        #expect(out.length == 192_000, "the MP3 length is \(out.length), not 192000", sourceLocation: sourceLocation)
    }

    /// Writes `samples` as a mono 32-bit float CAF and adds it to the pool.
    static func addFloatFile(_ package: MixPackage, _ id: FileID, _ samples: [Float]) throws {
        let rate = Double(package.session.sampleRate)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        buffer.floatChannelData![0].update(from: samples, count: samples.count)
        let path = "\(id.rawValue).caf"
        let file = try AVAudioFile(
            forWriting: package.url.appending(path: "\(clipsFolderName)/\(path)"), settings: format.settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        try package.session.addFile(AudioFile(id: id, path: path, layout: .mono, length: Frames(samples.count)))
    }
}
