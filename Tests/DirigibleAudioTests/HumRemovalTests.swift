import AVFoundation
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// Hum removal in a clip render (decision 0054): the `AVAudioUnitEQ` band-stop at f, 2f, 3f, and
/// 4f in the engine graph, mono and stereo, at 48 and 44.1 kHz.
struct HumRemovalTests {
    /// A sine at `hertz` of 4 s at 0.25, on each of `channels`, at `rate`.
    static func sine(_ hertz: Double, rate: Int, channels: Int) -> [[Float]] {
        let wave = (0..<(4 * rate)).map { Float(0.25 * sin(2 * Double.pi * hertz * Double($0) / Double(rate))) }
        return Array(repeating: wave, count: channels)
    }

    /// The cut in dB of each sine of `hertz` by `hum` alone: the RMS of the last 2 s, in over out.
    static func cuts(
        _ hertz: [Double], hum: Hum, channels: Int, rate: Int
    ) throws -> [Double: Double] {
        let fixture = try RenderFixture(rate: rate)
        var sines: [ClipID: (hertz: Double, samples: [Float])] = [:]
        for (index, value) in hertz.enumerated() {
            let wave = sine(value, rate: rate, channels: channels)
            let id = ClipID("c\(index)")
            try fixture.add(
                FileID("s\(index)"), wave, track: TrackID("t\(index)"), clips: [(id, 0, wave[0].count)])
            sines[id] = (value, wave.flatMap { $0 })
        }
        let outcome = try renderClips(
            [(Array(sines.keys), Treatment(.hum(hum)))], of: fixture.package.session, in: fixture.package.url,
            freeBytes: { .max }, isDownloaded: { _ in true })
        var cuts: [Double: Double] = [:]
        for (id, sine) in sines {
            let out = try fixture.samples(try #require(outcome.session.clip(id)?.clip.file), in: outcome.session)
            let from = 2 * rate * channels
            cuts[sine.hertz] = rmsDecibels(sine.samples, from: from) - rmsDecibels(out, from: from)
        }
        return cuts
    }

    /// C17 at 50 Hz: each band goes down 30 dB or more, 0.2 Hz off a band 20 dB or more, 75 Hz
    /// stays within 1.0 dB, and 1 kHz within 0.5 dB. The render at `humOctaves`: 68 to 111 dB,
    /// 24.8, 0.12, and 0.0002 dB. The band cuts are a record value of the narrow harmonic bands.
    @Test(arguments: [(1, 48_000), (2, 48_000), (1, 44_100), (2, 44_100)])
    func humRemoval50(channels: Int, rate: Int) throws {
        let cuts = try Self.cuts(
            [50, 100, 150, 200, 49.8, 50.2, 75, 1_000, 180], hum: .hz50, channels: channels, rate: rate)

        let label = "channels \(channels) at \(rate) Hz: \(cuts.sorted { $0.key < $1.key })"
        for band in [50.0, 100, 150, 200] { #expect(cuts[band, default: 0] >= 30, "band \(band); \(label)") }
        for near in [49.8, 50.2] { #expect(cuts[near, default: 0] >= 20, "\(near) Hz; \(label)") }
        #expect(abs(cuts[75, default: 99]) <= 1.0, "75 Hz; \(label)")
        #expect(abs(cuts[1_000, default: 99]) <= 0.5, "1 kHz; \(label)")
        print("C17 record: hum 50 band cuts \([50.0, 100, 150, 200].map { cuts[$0, default: .nan] }) dB, \(label)")
    }

    /// C17 at 60 Hz: the bands 60 to 240 Hz 30 dB or more, 59.8 and 60.2 Hz 20 dB or more, 90 Hz
    /// within 1.0 dB, and 1 kHz within 0.5 dB. The render at `humOctaves`: 80 to 123 dB, 26.4,
    /// 0.12, and 0.0004 dB. The band cuts are a record value of the narrow harmonic bands.
    @Test(arguments: [(1, 48_000), (2, 48_000), (1, 44_100), (2, 44_100)])
    func humRemoval60(channels: Int, rate: Int) throws {
        let cuts = try Self.cuts(
            [60, 120, 180, 240, 59.8, 60.2, 90, 1_000, 210], hum: .hz60, channels: channels, rate: rate)

        let label = "channels \(channels) at \(rate) Hz: \(cuts.sorted { $0.key < $1.key })"
        for band in [60.0, 120, 180, 240] { #expect(cuts[band, default: 0] >= 30, "band \(band); \(label)") }
        for near in [59.8, 60.2] { #expect(cuts[near, default: 0] >= 20, "\(near) Hz; \(label)") }
        #expect(abs(cuts[90, default: 99]) <= 1.0, "90 Hz; \(label)")
        #expect(abs(cuts[1_000, default: 99]) <= 0.5, "1 kHz; \(label)")
        print("C17 record: hum 60 band cuts \([60.0, 120, 180, 240].map { cuts[$0, default: .nan] }) dB, \(label)")
    }

    /// C17 and M1b: a voice harmonic between the hum bands stays within 0.5 dB, so hum alone keeps
    /// the voice. Probe probe-m1b-band: 0.015 octaves at 2f to 4f cut 180 Hz (hum 50) and 210 Hz
    /// (hum 60) by 0.02 dB; 0.2 octaves at each band cut them by 2.20 and 1.90 dB.
    @Test(arguments: [(1, 48_000), (2, 48_000), (1, 44_100), (2, 44_100)])
    func aSineBetweenTheBandsStays(channels: Int, rate: Int) throws {
        let at50 = try Self.cuts([180], hum: .hz50, channels: channels, rate: rate)
        let at60 = try Self.cuts([210], hum: .hz60, channels: channels, rate: rate)

        let label = "channels \(channels) at \(rate) Hz"
        #expect(abs(at50[180, default: 99]) <= 0.5, "180 Hz with hum 50: \(at50); \(label)")
        #expect(abs(at60[210, default: 99]) <= 0.5, "210 Hz with hum 60: \(at60); \(label)")
    }

    /// C17: each hum band holds its type, frequency, width, and bypass in the unit after setup,
    /// while other threads make and release hum and voice units. The render reads only the unit
    /// values.
    @Test func eachHumBandHoldsItsParametersWhileOtherThreadsReleaseUnits() throws {
        final class Misses: @unchecked Sendable {
            let lock = NSLock()
            var found: [String] = []
        }
        let misses = Misses()
        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            for index in 0..<3_000 {
                if (thread + index) % 2 == 1 {
                    _ = try? EffectChain.voiceUnit(wet: 100, component: .soundIsolation)
                    continue
                }
                let hum: Hum = index % 4 < 2 ? .hz50 : .hz60
                let expected: [[Float]] = (0..<4).map {
                    [0, 6, Float(hum.rawValue * ($0 + 1)), $0 == 0 ? 0.2 : 0.015]
                }
                let filter = try? EffectChain.humFilter(hum)
                // AUNBandEQ: bypass, filter type, frequency, and bandwidth of band b are 1000 + b,
                // 2000 + b, 3000 + b, and 5000 + b.
                let stored: [[Float]] = (0..<4).map { band in
                    [1000, 2000, 3000, 5000].map { base in
                        var value: Float = .nan
                        if let filter {
                            AudioUnitGetParameter(
                                filter.audioUnit, AudioUnitParameterID(base + band), kAudioUnitScope_Global, 0, &value)
                        }
                        return value
                    }
                }
                guard stored != expected else { continue }
                misses.lock.lock()
                misses.found.append("hum \(hum.rawValue): \(stored)")
                misses.lock.unlock()
            }
        }
        #expect(misses.found.isEmpty, "\(misses.found.count) of 12000 hum stages: \(misses.found.prefix(3))")
    }

    /// C17b: hum alone loads no voice unit: with a description that finds no component, the clip
    /// still moves to "<stem> HR". The same description fails a noise render with -3000.
    @Test func humAloneNeedsNoVoiceUnit() throws {
        let fixture = try RenderFixture()
        let wave = Self.sine(50, rate: 48_000, channels: 1)
        try fixture.add("f1", wave, track: "t1", clips: [("c1", 0, wave[0].count)])
        let missing = AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: 0x6E6F_6E65, componentManufacturer: 0x6E6F_6E65,
            componentFlags: 0, componentFlagsMask: 0)

        let outcome = try renderClips(
            [(["c1"], Treatment(.hum(.hz50)))], of: fixture.package.session, in: fixture.package.url,
            freeBytes: { .max }, component: { _ in missing }, isDownloaded: { _ in true })

        #expect(outcome.made.map(\.lastPathComponent) == ["f1 HR.wav"])
        let moved = try #require(outcome.session.clip("c1")?.clip.file)
        #expect(outcome.session.files[moved]?.path == "f1 HR.wav")
        #expect(throws: ClipRenderError.effectUnavailable(status: -3000)) {
            try renderClips(
                [(["c1"], Treatment(.noise(.standard)))], of: fixture.package.session, in: fixture.package.url,
                freeBytes: { .max }, component: { _ in missing }, isDownloaded: { _ in true })
        }
    }

    /// C17b: a clip on a music track and a clip on an effects track render with hum alone.
    @Test func humAloneTakesEachRole() throws {
        let fixture = try RenderFixture()
        let wave = Self.sine(50, rate: 48_000, channels: 1)
        try fixture.add("m", wave, track: "music", role: .music, clips: [("cm", 0, wave[0].count)])
        try fixture.add("e", wave, track: "effects", role: .effects, clips: [("ce", 0, wave[0].count)])

        let outcome = try renderClips(
            [(["cm", "ce"], Treatment(.hum(.hz50)))], of: fixture.package.session, in: fixture.package.url,
            freeBytes: { .max }, isDownloaded: { _ in true })

        #expect(outcome.made.map(\.lastPathComponent).sorted() == ["e HR.wav", "m HR.wav"])
        #expect(Set(outcome.clips.map(\.clip)) == ["cm", "ce"])
    }

    /// C17b: hum with noise renders through one graph: a 50 Hz sine goes down 30 dB or more, noise
    /// with no voice 11 to 13 dB (C4), equal channels stay equal past the latency (C5), the output
    /// has the span length, and it equals hum alone, then noise alone of that output. The EQ after
    /// the voice unit, or a latency that counts the unit twice, breaks the equality.
    @Test(arguments: [(1, 48_000), (2, 48_000), (1, 44_100), (2, 44_100)])
    func humAndNoiseInTheGraph(channels: Int, rate: Int) throws {
        let fixture = try RenderFixture(rate: rate)
        let sine = Self.sine(50, rate: rate, channels: channels)
        let noise = Array(repeating: seededNoise(frames: 10 * rate, level: 0.0562, seed: 8), count: channels)
        try fixture.add("s", sine, track: "ts", clips: [("cs", 0, sine[0].count)])
        try fixture.add("n", noise, track: "tn", clips: [("cn", 0, noise[0].count)])
        let both = try #require(Treatment([.hum(.hz50), .noise(.standard)]))

        let joint = try renderClips(
            [(["cs", "cn"], both)], of: fixture.package.session, in: fixture.package.url, freeBytes: { .max },
            isDownloaded: { _ in true })
        let hum = try renderClips(
            [(["cn"], Treatment(.hum(.hz50)))], of: fixture.package.session, in: fixture.package.url,
            freeBytes: { .max }, isDownloaded: { _ in true })
        let chained = try renderClips(
            [(["cn"], Treatment(.noise(.standard)))], of: hum.session, in: fixture.package.url, freeBytes: { .max },
            isDownloaded: { _ in true })

        let label = "channels \(channels) at \(rate) Hz"
        let sineOut = try fixture.samples(try #require(joint.session.clip("cs")?.clip.file), in: joint.session)
        let noiseOut = try fixture.samples(try #require(joint.session.clip("cn")?.clip.file), in: joint.session)
        let step = try fixture.samples(try #require(chained.session.clip("cn")?.clip.file), in: chained.session)
        let from = 2 * rate * channels
        let sineCut = rmsDecibels(sine.flatMap { $0 }, from: from) - rmsDecibels(sineOut, from: from)
        let noiseCut = rmsDecibels(noise[0], from: rate) - rmsDecibels(noiseOut, from: rate * channels)
        #expect(sineCut >= 30, "50 Hz cut \(sineCut) dB; \(label)")
        #expect(noiseCut >= 11 && noiseCut <= 13, "noise cut \(noiseCut) dB; \(label)")
        #expect(noiseOut.count == noise[0].count * channels, "the span length; \(label)")
        try #require(step.count == noiseOut.count)
        let difference = maxError(noiseOut, step)
        #expect(difference <= 1e-5, "hum, then noise: \(difference); \(label)")
        print("C17b record: joint against hum then noise max \(difference), \(label)")
        if channels == 2 {
            let latency = try EffectChain(both, scale: 1, rate: Double(rate), channels: 2, component: .soundIsolation)
                .latency
            let gaps = stride(from: 2 * latency, to: noiseOut.count, by: 2).map { abs(noiseOut[$0] - noiseOut[$0 + 1]) }
            #expect((gaps.max() ?? 1) <= 1e-6, "L-R past the latency; \(label)")
        }
    }
}
