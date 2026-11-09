import AVFoundation
import Accelerate
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The formats, the mono fold, the rate, and the source of `exportMix` (export run criteria 1
/// to 8). Tolerances: a level ± 0.01 dB for PCM and FLAC, ± 0.1 dB for AAC (a 1 kHz sine, probe
/// P6), ± 0.05 dB after a rate change; a length exact, or ± 1 frame after a rate change; FLAC
/// and WAV bit-exact.
struct ExportTests {
    /// The facts and the samples of an exported file.
    struct Written {
        let format: AudioStreamBasicDescription
        let length: Int
        let channels: [[Float]]
        var rate: Double { format.mSampleRate }
    }

    /// Reads an exported file in blocks as float channels.
    static func read(_ url: URL) throws -> Written {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var channels = [[Float]](repeating: [], count: Int(file.processingFormat.channelCount))
        while file.framePosition < file.length {
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            for (index, samples) in DirigibleAudioTests.channels(buffer).enumerated() {
                channels[index].append(contentsOf: samples)
            }
        }
        return Written(format: file.fileFormat.streamDescription.pointee, length: Int(file.length), channels: channels)
    }

    /// A 1 kHz sine at `rms` dBFS RMS, on the 24-bit grid of the WAV that holds it.
    static func tone(frames: Int, rms: Double = -20, rate: Double = 48_000, sign: Float = 1) -> [Float] {
        let steps: Double = 8_388_608 * 2.0.squareRoot() * pow(10, rms / 20)
        return (0..<frames).map { (i: Int) -> Float in
            let phase: Double = 2 * Double.pi * 1000 * Double(i) / rate
            return sign * Float((steps * sin(phase)).rounded() / 8_388_608)
        }
    }

    /// Seeded noise on the 24-bit grid, up to about -12 dBFS peak.
    static func noise(frames: Int, seed: UInt64) -> [Float] {
        var generator = SeededGenerator(seed: seed)
        return (0..<frames).map { _ in Float(Int.random(in: -2_000_000...2_000_000, using: &generator)) / 8_388_608 }
    }

    static func rmsDB(_ samples: [Float]) -> Double {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return 20 * log10(Double(rms))
    }

    static func peak(_ samples: [Float]) -> Float { samples.map(abs).max() ?? 0 }

    /// A package with one track `t1` and one clip of `channels` at 0.
    static func package(_ channels: [[Float]], rate: Int = 48_000) throws -> MixPackage {
        let package = try MixPackage(sampleRate: rate)
        try package.addFile("f1", channels: channels)
        try package.addTrack(
            "t1", layout: ChannelLayout(channelCount: channels.count)!, clip: "c1", file: "f1", start: 0, offset: 0,
            length: Frames(channels[0].count))
        return package
    }

    /// Exports `range` of `package` to `name` in its folder.
    static func export(
        _ package: MixPackage, _ range: Range<Frames>, tracks: Set<TrackID>? = nil, _ options: ExportOptions,
        to name: String
    ) throws -> URL {
        let url = package.folder.url.appending(path: name)
        let source = try #require(ExportSource(range: range, tracks: tracks))
        _ = try exportMix(package.session, source: source, options: options, to: url, package: { package.url })
        return url
    }

    static func options(_ format: ExportFormat, _ layout: ChannelLayout = .stereo, _ rate: ExportRate = .session)
        -> ExportOptions
    { ExportOptions(format: format, layout: layout, rate: rate) }

    @Test func aStereoWAV24HasTheFactsAndTheLevel() throws {
        let package = try Self.package([Self.tone(frames: 96_000)])

        let out = try Self.read(Self.export(package, 0..<96_000, Self.options(.wav(.bits24)), to: "mix.wav"))

        #expect(out.format.mFormatID == kAudioFormatLinearPCM)
        #expect(out.format.mChannelsPerFrame == 2)
        #expect(out.format.mBitsPerChannel == 24)
        #expect(out.rate == 48_000)
        #expect(out.length == 96_000)
        for channel in out.channels { #expect(abs(Self.rmsDB(channel) - -20) <= 0.01) }
    }

    /// Two mono tracks with the same file sum to twice each sample, so the mix reaches 1.5. The
    /// converter rounds half up and clips (probe P3): `floor(x * 32768 + 0.5)` in -32768...32767.
    /// The TPDF dither of decision 0032 moves each value by at most 1, and the clipped values stay.
    @Test func aWAV16RoundsAndClips() throws {
        let steps = [0.75, -0.75, 0.5, -0.5].map { Int($0 * 8_388_608) } + [64, -64, 63, -63, 65, -65, 192, -192]
        let values = (steps + Array(stride(from: -4_194_304, to: 4_194_304, by: 4099))).map { Float($0) / 8_388_608 }
        let package = try MixPackage()
        try package.addFile("f1", channels: [values])
        let length = Frames(values.count)
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: length)
        try package.addTrack("t2", clip: "c2", file: "f1", start: 0, offset: 0, length: length)

        let out = try Self.read(Self.export(package, 0..<length, Self.options(.wav(.bits16), .mono), to: "mix.wav"))

        #expect(out.format.mBitsPerChannel == 16)
        let integers = out.channels[0].map { Int(($0 * 32768).rounded()) }
        let expected = values.map { min(max(Int((Double(2 * $0) * 32768 + 0.5).rounded(.down)), -32768), 32767) }
        let near = zip(integers, expected).allSatisfy { abs($0 - $1) <= 1 }
        #expect(integers.count == expected.count && near, "a value is more than 1 from the rounded value")
        #expect(integers.prefix(2) == [32767, -32768])
    }

    @Test(arguments: [BitDepth.bits16, .bits24])
    func flacEqualsWAVBitForBit(bits: BitDepth) throws {
        let frames = 144_000
        let package = try Self.package([Self.noise(frames: frames, seed: 1), Self.noise(frames: frames, seed: 2)])
        let other: BitDepth = bits == .bits16 ? .bits24 : .bits16

        let flac = try Self.read(Self.export(package, 0..<Frames(frames), Self.options(.flac(bits)), to: "mix.flac"))
        let wav = try Self.read(Self.export(package, 0..<Frames(frames), Self.options(.wav(bits)), to: "mix.wav"))
        let wavOther = try Self.read(
            Self.export(package, 0..<Frames(frames), Self.options(.wav(other)), to: "other.wav"))

        #expect(flac.format.mFormatID == kAudioFormatFLAC)
        #expect(flac.length == frames)
        #expect(flac.channels == wav.channels)
        #expect(flac.channels != wavOther.channels)
    }

    @Test func anAACExportHasTheFactsAndTheLevel() throws {
        let package = try Self.package([Self.tone(frames: 192_000)])

        let out = try Self.read(Self.export(package, 0..<192_000, Self.options(.aac(.k128)), to: "mix.m4a"))

        #expect(out.format.mFormatID == kAudioFormatMPEG4AAC)
        #expect(out.format.mChannelsPerFrame == 2)
        #expect(out.rate == 48_000)
        #expect(out.length == 192_000)
        for channel in out.channels { #expect(abs(Self.rmsDB(channel) - -20) <= 0.1) }
    }

    /// 20 s of stereo noise: the file at 256 kbit/s is more than 2.5 times the file at 64.
    @Test func theAACBitRateApplies() throws {
        let frames = 960_000
        let package = try Self.package([Self.noise(frames: frames, seed: 3), Self.noise(frames: frames, seed: 4)])

        let low = try Self.export(package, 0..<Frames(frames), Self.options(.aac(.k64)), to: "low.m4a")
        let high = try Self.export(package, 0..<Frames(frames), Self.options(.aac(.k256)), to: "high.m4a")

        let lowSize = try #require(try FileManager.default.attributesOfItem(atPath: low.path)[.size] as? Int)
        let highSize = try #require(try FileManager.default.attributesOfItem(atPath: high.path)[.size] as? Int)
        #expect(Double(highSize) > 2.5 * Double(lowSize), "\(highSize) and \(lowSize) bytes")
    }

    /// The mono law 0.5 x (L + R): (a) a mono track keeps its level, (b) L alone is 6.02 dB
    /// lower, (c) L = -R is silence.
    @Test func theMonoFoldIsHalfTheSum() throws {
        let tone = Self.tone(frames: 96_000)
        let silence = [Float](repeating: 0, count: 96_000)
        let cases: [(String, [[Float]], Double?)] = [
            ("mono", [tone], -20), ("left only", [tone, silence], -26.02),
            ("left = -right", [tone, tone.map { -$0 }], nil),
        ]
        for (name, channels, level) in cases {
            let package = try Self.package(channels)

            let out = try Self.read(Self.export(package, 0..<96_000, Self.options(.wav(.bits24), .mono), to: "mix.wav"))

            #expect(out.format.mChannelsPerFrame == 1, "\(name)")
            if let level {
                #expect(abs(Self.rmsDB(out.channels[0]) - level) <= 0.01, "\(name)")
            } else {
                #expect(Self.peak(out.channels[0]) == 0, "\(name)")
            }
        }
    }

    /// 8 s of a 1 kHz sine from a 48 kHz session into a 44.1 kHz file.
    @Test(arguments: [ExportFormat.wav(.bits24), .flac(.bits24), .aac(.k128)])
    func aRateChangeKeepsPitchLevelAndLength(format: ExportFormat) throws {
        let package = try Self.package([Self.tone(frames: 384_000)])
        let name = if case .aac = format { "mix.m4a" } else if case .flac = format { "mix.flac" } else { "mix.wav" }

        let out = try Self.read(Self.export(package, 0..<384_000, Self.options(format, .mono, .hz44100), to: name))

        #expect(out.rate == 44_100)
        #expect(abs(out.length - 352_800) <= 1)
        let samples = out.channels[0]
        let crossings = zip(samples, samples.dropFirst()).count { $0 < 0 && $1 >= 0 }
        let frequency = Double(crossings) / (Double(out.length) / 44_100)
        #expect(abs(frequency - 1000) <= 1, "\(frequency) Hz")
        let tolerance = if case .aac = format { 0.1 } else { 0.05 }
        #expect(abs(Self.rmsDB(samples) - -20) <= tolerance, "\(Self.rmsDB(samples)) dB")
    }

    @Test func aacAbove48kHzIsRefused() throws {
        let package = try Self.package([Self.tone(frames: 96_000, rate: 96_000)], rate: 96_000)

        #expect(throws: ExportError.rateNotSupported(96_000)) {
            try Self.export(package, 0..<96_000, Self.options(.aac(.k128)), to: "mix.m4a")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: package.folder.url.path) == ["Mix.dirigible"])
    }

    /// Track t1 has audio in 48 000..<96 000, track t2 in 96 000..<144 000. The export of
    /// 48 000..<144 000 on t2 only has silence where only t1 has audio.
    @Test func aSelectionExportHasItsRangeAndTracks() throws {
        let package = try MixPackage()
        try package.addFile("f1", channels: [Self.tone(frames: 48_000)])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 48_000, offset: 0, length: 48_000)
        try package.addTrack("t2", clip: "c2", file: "f1", start: 96_000, offset: 0, length: 48_000)

        let out = try Self.read(
            Self.export(package, 48_000..<144_000, tracks: ["t2"], Self.options(.wav(.bits24)), to: "mix.wav"))

        #expect(out.length == 96_000)
        for channel in out.channels {
            #expect(Self.peak(Array(channel[0..<48_000])) == 0)
            #expect(abs(Self.rmsDB(Array(channel[48_000...])) - -20) <= 0.01)
        }
    }

    /// The session ends at 150 001, which is not a whole number of 48 000-frame chunks.
    @Test func aSessionExportEndsAtTheSessionEnd() throws {
        let package = try Self.package([Self.tone(frames: 150_001)])
        #expect(package.session.end == 150_001)

        let out = try Self.read(
            Self.export(package, 0..<package.session.end, Self.options(.wav(.bits24)), to: "mix.wav"))

        #expect(out.length == 150_001)
        #expect(abs(Self.rmsDB(Array(out.channels[0][144_000...])) - -20) <= 0.01)
    }

    /// Fades C13: a WAV 24-bit export with loudness Off has the fades of the play (C12 ties the
    /// play to the mix), within 2^-22 per sample.
    @Test func fadesExportAsTheyPlay() throws {
        let package = try fadedPackage()
        let out = try Self.read(Self.export(package, 0..<6000, Self.options(.wav(.bits24)), to: "fades.wav"))
        let expected = try fadedMix(0..<6000)
        #expect(out.channels.count == 2)
        for channel in out.channels {
            #expect(maxError(channel, expected) <= 1.0 / 4_194_304, "the export has the fades within 2^-22")
        }
    }

    /// Crossfades X3: a WAV 24-bit export has the crossfade of the play, within 2^-22 per sample.
    @Test func aCrossfadeExportsAsItPlays() throws {
        let package = try crossfadedPackage()
        let out = try Self.read(Self.export(package, 0..<22_000, Self.options(.wav(.bits24)), to: "crossfade.wav"))
        let expected = crossfadedMix(0..<22_000)
        #expect(out.channels.count == 2)
        for (channel, values) in zip(out.channels, expected) {
            #expect(maxError(channel, values) <= 1.0 / 4_194_304, "the export has the crossfade within 2^-22")
        }
    }

    /// Leveler C29: a WAV 24-bit export of a clip with an envelope and a ride has the gain of both
    /// layers within 1e-5 relative, and equals the play within 2^-23 per sample.
    @Test func aRideExportsAsItPlays() throws {
        let source = [Float](repeating: 0.5, count: 24_000)
        let package = try Self.package([source, source])
        let (envelope, ride) = try (
            MixTests.envelope([(4_000, 0), (12_000, -12)]), MixTests.envelope([(0, 3), (8_000, -3), (20_000, 6)])
        )
        try package.session.setEnvelopes(["c1": envelope])
        try package.session.setRides(["c1": ride])
        let out = try Self.read(Self.export(package, 0..<24_000, Self.options(.wav(.bits24)), to: "ride.wav"))
        let expected = (0..<24_000).map { k in
            0.5 * pow(10, (MixTests.decibels(envelope.points, at: k) + MixTests.decibels(ride.points, at: k)) / 20)
        }
        let played = try package.mix(0..<24_000)
        #expect(out.channels.count == 2)
        for (channel, values) in out.channels.enumerated() {
            let error = MixLayersTests.relativeError(values, expected)
            #expect(error.error <= 1e-5, "channel \(channel): \(error.error) at frame \(error.frame)")
            #expect(maxError(values, played[channel]) <= 1.0 / 8_388_608, "channel \(channel) equals the play")
        }
    }

    /// Crossfades X2: the preflight of a range from J + 1 checks the file of A, which sounds there
    /// from its handle, and not the file of a clip that ends before the crossfade (C on t2).
    @Test func aRangeInsideACrossfadeChecksBothFiles() throws {
        let package = try crossfadedPackage()
        try package.addFile("other", channels: [[Float](repeating: 0, count: 1_000)])
        try package.addTrack("t2", clip: "C", file: "other", start: 10_000, offset: 0, length: 700)
        for file in ["left", "other"] {
            try FileManager.default.removeItem(at: package.url.appending(path: "\(clipsFolderName)/\(file).wav"))
        }
        let source = try #require(ExportSource(range: 11_001..<11_100))
        #expect(
            try checkMedia(package.session, package: package.url, source: source) == ["left": .missing],
            "only the file of A is missing in the range")
    }

    /// Mute and solo C3: a float CAF export with t1 muted has only t2 (0.5) at each frame.
    @Test func anExportLeavesOutAMutedTrack() throws {
        let package = try MixPackage()
        try package.addFile("f1", channels: [[Float](repeating: 0.25, count: 48_000)])
        try package.addFile("f2", channels: [[Float](repeating: 0.5, count: 48_000)])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 48_000)
        try package.addTrack("t2", clip: "c2", file: "f2", start: 0, offset: 0, length: 48_000)
        try package.session.setMuted(true, tracks: ["t1"])

        let out = try Self.read(Self.export(package, 0..<48_000, Self.options(.floatCAF), to: "mix.caf"))

        #expect(out.length == 48_000)
        #expect(out.channels.count == 2 && out.channels.allSatisfy { $0.allSatisfy { $0 == 0.5 } }, "only t2 is heard")
    }
}

/// `ExportSource.init?` refuses a source with no frame or no track (export run criterion 8).
struct ExportSourceTests {
    @Test func anEmptyRangeOrTrackSetIsRefused() {
        #expect(ExportSource(range: 5..<5) == nil)
        #expect(ExportSource(range: -1..<5) == nil)
        #expect(ExportSource(range: 0..<(Frames.limit + 1)) == nil)
        #expect(ExportSource(range: 0..<5, tracks: []) == nil)
        #expect(ExportSource(range: 4..<5)?.range == 4..<5)
        #expect(ExportSource(range: 0..<Frames.limit, tracks: ["t1"])?.tracks == ["t1"])
    }
}
