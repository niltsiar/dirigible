import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Criteria C2 to C4, C19, and C26 of decision 0074 (D1, D2): the match stage of a track in
/// `MixReader`. The oracle filters the unmatched render of the track over the range plus the
/// context with one `MatchFilter` call, then gates it, so a render that fits the span of its reader
/// gives the oracle bit for bit.
struct MixReaderMatchTests {
    static let context = 8_192
    static let rampLength = 768
    static let tilt = ThirdOctave.Gains(decibels: (0..<25).map { -12 + Double($0) })!
    static let curves: [ThirdOctave.Gains] = [
        tilt, ThirdOctave.Gains(decibels: (0..<25).map { 12 - Double($0) })!,
        ThirdOctave.Gains(decibels: (0..<25).map { $0 == 12 ? 12 : 0 })!,
        ThirdOctave.Gains(decibels: (0..<25).map { $0 == 1 ? -12 : 0 })!,
    ]

    /// A match at amount 100 with flat target powers.
    static func match(_ curve: ThirdOctave.Gains = tilt, bypassed: Bool = false) throws -> VoiceMatch {
        try VoiceMatch(
            amount: #require(VoiceMatch.Amount(100)), isBypassed: bypassed, reference: "Host 01", curve: curve.decibels,
            targetPowers: [Double](repeating: 1, count: 25))
    }

    /// Noise from -0.5 to 0.5, each value a multiple of 2^-23, so a 24-bit WAV holds it exactly.
    static func noise(_ frames: Int, seed: UInt64 = 1) -> [Float] {
        var state = seed
        return (0..<frames).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int(state >> 41) - 4_194_304) / 8_388_608
        }
    }

    /// The gate of D2 at a frame `distance` frames outside an edge with ramp `length`.
    static func gate(_ distance: Int, _ length: Int = rampLength) -> Float {
        distance <= 0
            ? 1 : distance < length ? Float(0.5 * (1 + cos(Double.pi * Double(distance) / Double(length)))) : 0
    }

    /// The ungated stage output of track `track` over `range`: its unmatched render over the range
    /// plus the context, zeros before frame 0, through one filter call.
    static func ungated(_ package: MixPackage, _ track: TrackID, _ range: Range<Int>) throws -> [[Float]] {
        var session = package.session
        try session.removeMatch(tracks: [track])
        let match = try #require(package.session.tracks.first { $0.id == track }?.match)
        let gains = match.gains(at: match.amount)
        let low = max(0, range.lowerBound - context)
        let plain = try package.render(
            MixReader(package: package.url, session: session, tracks: [track]),
            Frames(low)..<Frames(range.upperBound + context))
        let filter = MatchFilter(sampleRate: package.session.sampleRate)
        let kernel = filter.kernel(gains)
        return plain.map { channel in
            let input = [Float](repeating: 0, count: low - (range.lowerBound - context)) + channel
            var output = [Float](repeating: 0, count: range.count)
            input.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { filter.filter(input, through: kernel, into: $0) }
            }
            return output
        }
    }

    /// A package with one stereo noise file of `frames` and track t1 with clip A on it.
    static func package(clip range: Range<Int>, frames: Int = 120_000, curve: ThirdOctave.Gains = tilt) throws
        -> MixPackage
    {
        let package = try MixPackage()
        try package.addFile("n", channels: [noise(frames, seed: 1), noise(frames, seed: 2)])
        try package.addTrack(
            "t1", layout: .stereo, clip: "A", file: "n", start: Frames(range.lowerBound), offset: 0,
            length: Frames(range.count))
        try package.session.setMatch(["t1": match(curve)])
        return package
    }

    @Test func oneOutputForEachReadPattern() throws {
        let package = try MixPackage()
        try package.addFile("n", channels: [Self.noise(600_000, seed: 1), Self.noise(600_000, seed: 2)])
        try package.addTrack("t1", layout: .stereo, clip: "A", file: "n", start: 24_000, offset: 0, length: 226_000)
        try package.session.place(Clip(id: "B", file: "n", start: 260_000, offset: 300_000, length: 260_000), on: "t1")
        try package.session.setMatch(["t1": Self.match()])
        let whole = try package.mix(0..<480_000)
        let ungated = try Self.ungated(package, "t1", 0..<480_000)
        let gates = (0..<480_000).map { t in
            max(Self.gate(max(24_000 - t, t - 250_000 + 1)), Self.gate(max(260_000 - t, t - 520_000 + 1)))
        }
        for channel in 0..<2 {
            let expected = zip(ungated[channel], gates).map { $0 * $1 }
            #expect(maxError(whole[channel], expected) <= 1e-5, "one call against the oracle, channel \(channel)")
        }
        #expect(whole[0][100_000] != 0)
        for (size, step) in [(4_800, 4_800), (4_801, 4_799), (48_000, 48_000)] {
            let reader = package.reader()
            var (start, error) = (0, Float(0))
            while start + size <= 480_000 {
                let part = try package.render(reader, Frames(start)..<Frames(start + size))
                for channel in 0..<2 {
                    error = max(error, maxError(part[channel], Array(whole[channel][start..<start + size])))
                }
                start += step
            }
            #expect(error <= 1e-5, "chunks of \(size) every \(step) frames")
        }
        let reader = package.reader()
        for start in stride(from: 0, to: 480_000, by: 48_000) {
            let range = Frames(start)..<Frames(start + 4_800)
            let (first, again) = try (package.render(reader, range), package.render(reader, range))
            #expect(first == again, "the crossfade read again at \(start)")
            #expect(maxError(first[0], Array(whole[0][start..<start + 4_800])) <= 1e-5)
        }
    }

    @Test func noMatchIsBitEqual() throws {
        let package = try MixPackage()
        try package.addFile("r", channels: [ramp(frames: 60_000)])
        try package.addTrack("t1", clip: "A", file: "r", start: 1_000, offset: 0, length: 50_000)
        let mix = try package.mix(0..<60_000)
        let expected = [Float](repeating: 0, count: 1_000) + ramp(frames: 50_000) + [Float](repeating: 0, count: 9_000)
        #expect(mix[0] == expected)
        #expect(mix[1] == expected)
    }

    @Test func bypassIsBitEqual() throws {
        let package = try Self.package(clip: 10_000..<70_000)
        var plain = package.session
        try plain.removeMatch(tracks: ["t1"])
        try package.session.setMatchBypassed(true, tracks: ["t1"])
        #expect(try package.mix(0..<90_000) == package.mix(0..<90_000, session: plain))
    }

    @Test func otherTracksKeepTheirSamples() throws {
        let package = try Self.package(clip: 10_000..<70_000)
        try package.addFile("r", channels: [ramp(frames: 60_000)])
        try package.addTrack("t2", clip: "B", file: "r", start: 5_000, offset: 0, length: 60_000)
        let both = try package.mix(0..<90_000)
        let matched = try package.render(
            MixReader(package: package.url, session: package.session, tracks: ["t1"]), 0..<90_000)
        let plain = try package.render(
            MixReader(package: package.url, session: package.session, tracks: ["t2"]), 0..<90_000)
        #expect(
            plain[0] == [Float](repeating: 0, count: 5_000) + ramp(frames: 60_000)
                + [Float](repeating: 0, count: 25_000))
        for channel in 0..<2 { #expect(both[channel] == zip(matched[channel], plain[channel]).map { $0 + $1 }) }
    }

    /// C3: a 0 dBFS burst 20 ms past the clip end in the file is never heard.
    @Test func cutAwayAudioIsNeverHeard() throws {
        let low = try #require(ThirdOctave.Gains(decibels: (0..<25).map { $0 < 6 ? 12 : 0 }))
        var mixes: [[[Float]]] = []
        for burst in [true, false] {
            var samples = Self.noise(80_000)
            for frame in 30_960..<35_760 { samples[frame] = burst ? (frame % 2 == 0 ? 1 : -1) : 0 }
            let package = try MixPackage()
            try package.addFile("n", channels: [samples])
            try package.addTrack("t1", clip: "A", file: "n", start: 10_000, offset: 0, length: 30_000)
            try package.session.setMatch(["t1": Self.match(low)])
            mixes.append(try package.mix(0..<70_000))
        }
        #expect(mixes[0] == mixes[1])
    }

    @Test func splitPlaysAsTheUnsplitClip() throws {
        let package = try Self.package(clip: 10_000..<90_000)
        let unsplit = try package.mix(0..<100_000)
        try package.session.split("A", at: 50_000, rightID: "A2")
        #expect(try package.mix(0..<100_000) == unsplit)
    }

    @Test func sessionStartReadsZeros() throws {
        let package = try Self.package(clip: 0..<30_000)
        let mix = try package.mix(0..<9_600)
        let expected = try Self.ungated(package, "t1", 0..<9_600)
        #expect(mix == expected)
    }

    @Test func clipGainScalesTheOutput() throws {
        let (zero, low) = try (#require(Gain(dB: 0)), #require(Gain(dB: -9)))
        let envelope = try #require(GainEnvelope([.init(frame: 5_000, gain: zero), .init(frame: 20_000, gain: low)]))
        let package = try MixPackage()
        try package.addFile("n", channels: [Self.noise(60_000)])
        try package.addTrack(
            "t1", clip: "A", file: "n", start: 10_000, offset: 0, length: 40_000, envelope: envelope)
        try package.session.setFades(["A": #require(Fades(fadeIn: 2_000, fadeOut: 3_000))])
        try package.session.setMatch(["t1": Self.match()])
        let plain = try package.mix(0..<60_000)
        try package.session.setGain(#require(Gain(dB: 20 * log10(2))), clip: "A")
        let loud = try package.mix(0..<60_000)
        #expect(maxError(loud[0], plain[0].map { 2 * $0 }) <= 1e-5)
        #expect(plain[0].map(abs).max()! > 0.1)
    }

    /// C26: past the ramp outside a hard edge the output is digital zero; inside the clip it is the
    /// ungated stage output, for each curve.
    @Test(arguments: curves) func gapOutsideClipsIsSilent(curve: ThirdOctave.Gains) throws {
        let package = try Self.package(clip: 20_000..<34_400, curve: curve)
        let mix = try package.mix(0..<60_000)
        let ungated = try Self.ungated(package, "t1", 0..<60_000)
        for channel in 0..<2 {
            let outside = Array(0..<(20_000 - Self.rampLength + 1)) + Array((34_400 + Self.rampLength - 1)..<60_000)
            #expect(outside.allSatisfy { mix[channel][$0] == 0 })
            #expect(outside.contains { abs(ungated[channel][$0]) > 1e-6 }, "the ungated stage rings in the gap")
            #expect(Array(mix[channel][20_000..<34_400]) == Array(ungated[channel][20_000..<34_400]))
        }
    }

    /// C26: within R of a hard edge the output is the ungated output times the raised cosine, and
    /// the high-passed energy in the window from R + 16 ms outside the edge is at most 1 dB over the
    /// ungated one (or its peak is under -60 dB against the clip peak).
    @Test(arguments: curves) func gateRampAddsNoClick(curve: ThirdOctave.Gains) throws {
        let package = try Self.package(clip: 20_000..<34_400, curve: curve)
        let mix = try package.mix(0..<60_000)
        let ungated = try Self.ungated(package, "t1", 0..<60_000)
        let peak = Self.noise(14_400).map(abs).max()!
        for channel in 0..<2 {
            var shape = Float(0)
            for distance in 1..<Self.rampLength {
                for frame in [20_000 - distance, 34_400 - 1 + distance] {
                    shape = max(shape, abs(mix[channel][frame] - ungated[channel][frame] * Self.gate(distance)))
                }
            }
            #expect(shape <= 1e-6 * peak, "the ramp shape of channel \(channel)")
            let window = Self.rampLength + 768
            for frames in [(20_000 - window)..<20_000, 34_400..<(34_400 + window)] {
                let (gated, plain) = (highPassed(mix[channel], frames), highPassed(ungated[channel], frames))
                let rise = 10 * log10(gated.energy / plain.energy)
                #expect(rise <= 1 || 20 * log10(gated.peak / Double(peak)) < -60, "rise \(rise) dB at \(frames)")
            }
        }
    }

    @Test func gateFollowsTheEdgeFade() throws {
        let package = try Self.package(clip: 20_000..<50_000)
        try package.session.setFades(["A": #require(Fades(fadeIn: 1_920, fadeOut: 1_200))])
        let mix = try package.mix(0..<60_000)
        let ungated = try Self.ungated(package, "t1", 0..<60_000)
        var (start, end) = (Float(0), Float(0))
        for distance in 1..<2_400 {
            let (before, after) = (20_000 - distance, 50_000 - 1 + distance)
            start = max(start, abs(mix[0][before] - ungated[0][before] * Self.gate(distance, 1_920)))
            end = max(end, abs(mix[0][after] - ungated[0][after] * Self.gate(distance, 1_200)))
        }
        #expect(start <= 1e-7, "the ramp of the 40 ms fade-in")
        #expect(end <= 1e-7, "the ramp of the 25 ms fade-out")
        #expect(abs(mix[0][20_000 - 1_000]) > 0, "a frame past 16 ms outside the faded start")
    }

    /// Clips that touch make one extent; a gap shorter than two ramps takes the larger ramp.
    @Test func touchingClipsMakeOneExtent() throws {
        let package = try Self.package(clip: 10_000..<20_000)
        try package.addFile("m", channels: [Self.noise(40_000, seed: 5), Self.noise(40_000, seed: 6)])
        try package.session.place(Clip(id: "B", file: "m", start: 20_000, offset: 0, length: 10_000), on: "t1")
        try package.session.place(Clip(id: "C", file: "m", start: 31_000, offset: 20_000, length: 10_000), on: "t1")
        let mix = try package.mix(0..<50_000)
        let ungated = try Self.ungated(package, "t1", 0..<50_000)
        #expect(Array(mix[0][10_000..<30_000]) == Array(ungated[0][10_000..<30_000]))
        let gap = (30_000..<31_000).map { frame in
            abs(mix[0][frame] - ungated[0][frame] * max(Self.gate(frame - 30_000 + 1), Self.gate(31_000 - frame)))
        }
        #expect(gap.max()! <= 1e-7, "the gap of 1,000 frames takes the larger ramp")
    }
}

/// The energy and the peak over `frames` of `samples` through a linear-phase high-pass at 2 kHz
/// (511 taps, Blackman window) at 48 kHz, the metric of C26.
private func highPassed(_ samples: [Float], _ frames: Range<Int>) -> (energy: Double, peak: Double) {
    let (taps, middle, cutoff) = (511, 255, 2.0 * Double.pi * 2_000 / 48_000)
    let coefficients = (0..<taps).map { n -> Double in
        let k = Double(n - middle)
        let lowPass = n == middle ? cutoff / Double.pi : sin(cutoff * k) / (Double.pi * k)
        let phase = 2 * Double.pi * Double(n) / Double(taps - 1)
        return (n == middle ? 1 : 0) - lowPass * (0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase))
    }
    var (energy, peak) = (0.0, 0.0)
    for frame in frames {
        var sum = 0.0
        for n in 0..<taps where samples.indices.contains(frame + middle - n) {
            sum += coefficients[n] * Double(samples[frame + middle - n])
        }
        energy += sum * sum
        peak = max(peak, abs(sum))
    }
    return (energy, peak)
}
