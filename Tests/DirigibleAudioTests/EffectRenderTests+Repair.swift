import AVFoundation
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// A stage that multiplies each sample by `gain`, and that puts a NaN at frame `nan` of the stream
/// when it is set: the stand-in of a stage that makes the output louder or not finite.
struct TestStage: RenderStage {
    let latency = 0
    let held = 0
    let gain: Float
    let channels: Int
    var nan: Int?
    private var taken = 0

    init(gain: Float = 1, channels: Int = 1, nan: Int? = nil) {
        (self.gain, self.channels, self.nan) = (gain, channels, nan)
    }

    mutating func process(_ block: [[Float]]) -> [[Float]] {
        var output = block.map { $0.map { $0 * gain } }
        if let nan, (taken..<taken + block[0].count).contains(nan) { output[0][nan - taken] = .nan }
        taken += block[0].count
        return output
    }

    mutating func finish() -> [[Float]] { Array(repeating: [], count: channels) }
}

/// The 120 Hz U5g vowel of `RepairStageTests` 6 dB over, clipped at `level`, `seconds` long.
func clippedVowel(level: Float, seconds: Int = 1) -> [Float] {
    let one = clipped(swingVowel(120), over: 2).clipped.map { $0 * level }
    return (0..<seconds).flatMap { _ in one }
}

/// The repair effects in the clip render (decision 0064 D1, D4, D9): the chain order, the
/// alignment, the level loss, the measure step, and the guards.
extension EffectRenderTests {
    /// The import ceiling of `fullScaleRepair`: two 24-bit steps under full scale.
    static let ceiling = Float(1 - 0x1p-22)

    /// Renders `clips` of `fixture` with `treatment`.
    func repair(
        _ fixture: RenderFixture, _ clips: [ClipID], _ treatment: Treatment, of session: Session? = nil,
        readFault: ReadFault? = nil, addedStage: (any RenderStage)? = nil
    ) throws(ClipRenderError) -> ClipRenderOutcome {
        try renderClips(
            [(clips, treatment)], of: session ?? fixture.package.session, in: fixture.package.url,
            freeBytes: { .max }, readFault: readFault, isDownloaded: { _ in true }, addedStage: addedStage)
    }

    /// The s1 of `repairSetup` for the frames `span` of the file `file` of `fixture`.
    func measuredScale(_ fixture: RenderFixture, _ file: FileID, span: Range<Int>, _ treatment: Treatment) throws
        -> Float
    {
        let url = fixture.package.url.appending(path: "\(clipsFolderName)/\(file.rawValue).wav")
        let source = try AVAudioFile(forReading: url)
        let descriptor = open(url.path, O_RDONLY)
        defer { close(descriptor) }
        return try repairSetup(
            span: Int64(span.lowerBound)..<Int64(span.upperBound), of: source, descriptor: descriptor,
            treatment: treatment, file: url.lastPathComponent, stem: "measure", readFault: nil,
            isCancelled: { false }
        ).scale
    }

    /// C6: declip, rumble, hum, and deess render as the stages in chain order: the de-clip and the
    /// high-pass on the source, the hum band-stop in the engine, and the de-ess on its output, to
    /// 1e-6. A 50 Hz tone of 0.3 under the "s" shows the order: the de-ess before the band-stop sees
    /// the tone in its full band and cuts less. Fail: the de-ess before the unit. The reference
    /// band-stop gets the de-clip latency of zeros first, as the render engine does, so both pull the
    /// same blocks.
    @Test func repairChainOrder() throws {
        let fixture = try RenderFixture()
        let sibilant = sibilantSpeech()
        let speech: [Float] = sibilant.indices.map { frame in
            let phase = 2 * Double.pi * 50 * Double(frame) / 48_000
            return sibilant[frame] + 0.3 * Float(sin(phase))
        }
        let input: [Float] = speech.map { min(max($0, -0.3), 0.3) }
        try fixture.add("f1", [input], track: "t1", clips: [("c1", 0, input.count)])
        let deess = try #require(DeEss(hertz: 6_000, decibels: 10))
        let treatment = try #require(
            Treatment([.declip(.standard), .rumble(.standard), .hum(.hz50), .deess(deess)]))

        let outcome = try repair(fixture, ["c1"], treatment)

        let source = try fixture.source("f1", 0..<input.count, channels: 1)
        var declip = DeclipStage(percent: 99, peaks: [largest(source)], carriedBits: 24, rate: 48_000)
        var rumble = RumbleStage(hertz: 80, rate: 48_000, channels: 1)
        let filtered = [Float](repeating: 0, count: declip.latency) + render(&rumble, render(&declip, [source]))[0]
        #expect(declip.runs > 0, "the fixture has clipped runs")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(filtered.count)))
        buffer.frameLength = AVAudioFrameCount(filtered.count)
        buffer.floatChannelData![0].update(from: filtered, count: filtered.count)
        var hummed: [Float] = []
        _ = try EffectChain(
            Treatment(.hum(.hz50)), scale: 1, rate: 48_000, channels: 1, component: .soundIsolation, repair: .none
        ).render(
            buffer,
            into: { hummed += UnsafeBufferPointer(start: $0.floatChannelData![0], count: Int($0.frameLength)) },
            isCancelled: { false })
        hummed.removeFirst(declip.latency)
        var stage = DeEssStage(hertz: 6_000, decibels: 10, rate: 48_000, channels: 1)
        let expected = render(&stage, [hummed])[0]

        let rendered = try fixture.samples(try #require(outcome.session.clip("c1")?.clip.file), in: outcome.session)
        try #require(rendered.count == expected.count)
        #expect(maxError(rendered, expected) <= 1e-6)
        #expect(maxError(expected, hummed) > 1e-3, "the de-ess cuts the fixture")
    }

    /// The player starts with the first block scheduled: a hum render of a tone starts at frame 1
    /// (the first non-zero sample), not one pull (4,096 frames) later. Fail: `play()` at the engine
    /// start, which gives a silent first pull in most runs.
    @Test func humRenderKeepsTheFirstFrames() throws {
        let fixture = try RenderFixture()
        let tone = (0..<20_000).map { frame in Float(0.3 * sin(2 * Double.pi * 50 * Double(frame) / 48_000)) }
        try fixture.add("f1", [tone], track: "t1", clips: [("c1", 0, tone.count)])

        let outcome = try repair(fixture, ["c1"], Treatment(.hum(.hz50)))

        let output = try fixture.samples(try #require(outcome.session.clip("c1")?.clip.file), in: outcome.session)
        #expect(output.firstIndex { abs($0) > 1e-6 } == 1)
    }

    /// C4: the render drops the pre-stage latency (484 frames of the de-clip at 48 kHz): a click
    /// fixture renders through declip equal to the source, and through declip and rumble its
    /// cross-correlation with the source peaks at lag 0. Fail: lag 484 with the pre-stage latency
    /// left out of the drop.
    @Test func repairChainAligns() throws {
        let fixture = try RenderFixture()
        let clicks = stride(from: 9_000, to: 140_000, by: 13_331).map { $0 }
        var input = [Float](repeating: 0, count: 144_000)
        for frame in clicks { input[frame] = 0.5 }
        try fixture.add("f1", [input], track: "t1", clips: [("c1", 0, input.count)])
        try fixture.add("f2", [input], track: "t2", clips: [("c2", 0, input.count)])

        let alone = try repair(fixture, ["c1"], Treatment(.declip(.standard)))
        let both = try repair(fixture, ["c2"], try #require(Treatment([.declip(.standard), .rumble(.standard)])))

        let declipped = try fixture.samples(try #require(alone.session.clip("c1")?.clip.file), in: alone.session)
        #expect(declipped == input, "the de-clip finds no run in single clicks")
        let rumbled = try fixture.samples(try #require(both.session.clip("c2")?.clip.file), in: both.session)
        try #require(rumbled.count == input.count)
        let lags = -600...600
        let correlation = lags.map { lag in
            clicks.reduce(Float(0)) { sum, frame in
                let index = frame + lag
                return sum + (input.indices.contains(index) ? 0.5 * rumbled[index] : 0)
            }
        }
        let best = lags.lowerBound + (correlation.indices.max { correlation[$0] < correlation[$1] } ?? 0)
        #expect(best == 0, "the correlation peaks at lag \(best)")
    }

    /// C7: a de-clip whose filled peak is over full scale scales pass 1 by s1, so the file peaks
    /// at the import ceiling with no sample at an end code; the clip gain and the added gain stay
    /// 0 dB, and the outcome gives the runs and the drop -20 log10(s1). Fail: the 0054 rule (the
    /// clip gain grows by the scale).
    @Test func declipKeepsTheLevelLoss() throws {
        let fixture = try RenderFixture()
        let input = clippedVowel(level: 0.999)
        try fixture.add("f1", [input], track: "t1", clips: [("c1", 0, input.count)])
        let treatment = Treatment(.declip(.standard))
        let scale = try measuredScale(fixture, "f1", span: 0..<input.count, treatment)
        try #require(scale < 0.9, "the filled peak is over full scale: s1 \(scale)")

        let outcome = try repair(fixture, ["c1"], treatment)

        let clip = try #require(outcome.session.clip("c1")?.clip)
        let samples = try fixture.samples(clip.file, in: outcome.session)
        #expect(clip.gain == .zero, "the clip gain stays; fail: the 0054 rule")
        #expect(outcome.session.files[clip.file]?.origin?.addedGain == .zero)
        #expect(samples.allSatisfy { $0 > -1 && $0 < 0x1.fffffcp-1 }, "a sample at an end code")
        #expect(abs(20 * log10(Double(largest(samples) / Self.ceiling))) < 0.01, "the file peaks at the ceiling")
        let report = try #require(outcome.repairs["c1"])
        #expect(report.runs > 0)
        #expect(abs(report.levelDrop + 20 * log10(Double(scale))) < 0.01, "drop \(report.levelDrop), s1 \(scale)")
    }

    /// C7: a later stage that makes pass 1 louder than full scale (a gain of 1.5 after the de-ess)
    /// gives a second pass at s1 x s2: the file peaks at the ceiling, and the drop is
    /// -20 log10(s1) + 20 log10(1.5). Fail: the second pass at s2 alone, which drops s1 and throws
    /// `.stillOverFullScale`.
    @Test func secondPassScalesTheFilledOutput() throws {
        let fixture = try RenderFixture()
        let input = clippedVowel(level: 0.999)
        try fixture.add("f1", [input], track: "t1", clips: [("c1", 0, input.count)])
        let treatment = Treatment(.declip(.standard))
        let scale = try measuredScale(fixture, "f1", span: 0..<input.count, treatment)

        let outcome = try repair(fixture, ["c1"], treatment, addedStage: TestStage(gain: 1.5))

        let clip = try #require(outcome.session.clip("c1")?.clip)
        let samples = try fixture.samples(clip.file, in: outcome.session)
        #expect(clip.gain == .zero)
        #expect(samples.allSatisfy { $0 > -1 && $0 < 0x1.fffffcp-1 }, "a sample at an end code")
        #expect(abs(20 * log10(Double(largest(samples) / Self.ceiling))) < 0.01, "the file peaks at the ceiling")
        let expected = -20 * log10(Double(scale)) + 20 * log10(1.5)
        let drop = try #require(outcome.repairs["c1"]).levelDrop
        #expect(abs(drop - expected) < 0.01, "drop \(drop), expected \(expected)")
    }

    /// C7: a rumble render over full scale with no de-clip keeps the 0054 rule: the second pass
    /// scales it, and the clip gain gives the level back. A 20 Hz square of 0.99 through the 80 Hz
    /// high-pass gives edges near 1.9. Fail: a level loss for every repair kind.
    @Test func rumbleOverFullScaleKeepsTheGainRule() throws {
        let fixture = try RenderFixture()
        let square = (0..<48_000).map { Float(($0 / 1_200) % 2 == 0 ? 0.99 : -0.99) }
        try fixture.add("f1", [square], track: "t1", clips: [("c1", 0, square.count)])

        let outcome = try repair(fixture, ["c1"], Treatment(.rumble(.standard)))

        let clip = try #require(outcome.session.clip("c1")?.clip)
        let samples = try fixture.samples(clip.file, in: outcome.session)
        #expect(clip.gain.dB > 3, "the clip gain gives the level back: \(clip.gain.dB) dB")
        #expect(samples.allSatisfy { $0 > -1 && $0 < 0x1.fffffcp-1 }, "a sample at an end code")
        #expect(outcome.repairs["c1"] == nil, "no de-clip, no repair report")
    }

    /// C8: the de-clip level follows the peak of the run: the clipped vowel at a peak of 0.5 gets
    /// the runs that it gets at 0.999. Fail: a fixed level of full scale (0 runs at 0.5).
    @Test func declipFollowsTheRunPeak() throws {
        let fixture = try RenderFixture()
        let (loud, quiet) = (clippedVowel(level: 0.999), clippedVowel(level: 0.5))
        try fixture.add("loud", [loud], track: "t1", clips: [("l", 0, loud.count)])
        try fixture.add("quiet", [quiet], track: "t2", clips: [("q", 0, quiet.count)])

        let outcome = try repair(fixture, ["l", "q"], Treatment(.declip(.standard)))

        let (l, q) = (try #require(outcome.repairs["l"]).runs, try #require(outcome.repairs["q"]).runs)
        #expect(l > 0 && q == l, "runs at 0.999: \(l), at 0.5: \(q)")
    }

    /// C3: a 16-bit WAV with TPDF dither, imported into a 48 kHz package (a 24-bit WAV that holds
    /// 16 bits), keeps at least 95 % of the runs that the 1e-6 rule finds before the dither. Fail:
    /// the depth of the file format (24 bits), 25.0 %.
    @Test func declipFindsTheRunsOfA16BitImport() throws {
        let fixture = try RenderFixture()
        try fixture.package.session.addTrack("t1", name: "t1", layout: .mono)
        let truth = clippedVowel(level: 0.891)
        var reference = DeclipStage(percent: 99, peaks: [largest(truth)], carriedBits: 24, rate: 48_000)
        let runs = changedRanges(truth, render(&reference, [truth])[0])
        let input = dithered(truth.map(Double.init), bits: 16, seed: 1)
        let wav = fixture.package.folder.url.appending(path: "Hot.wav")
        try writeSource(wav, .wav16, rate: 48_000, channels: [input])
        let (session, clip) = try importAudio(
            wav, to: ImportTarget(track: "t1", start: 0), of: fixture.package.session, in: fixture.package.url,
            level: false)
        let imported = try fixture.samples(try #require(session.clip(clip)?.clip.file), in: session)
        try #require(imported == input, "the import keeps the 16-bit samples")

        let outcome = try repair(fixture, [clip], Treatment(.declip(.standard)), of: session)

        let report = try #require(outcome.repairs[clip])
        let scale = Float(pow(10, -report.levelDrop / 20))
        let output = try fixture.samples(try #require(outcome.session.clip(clip)?.clip.file), in: outcome.session)
        try #require(output.count == input.count)
        let changed = input.indices.filter { abs(output[$0] / scale - input[$0]) > 1e-5 }
        let found = runs.filter { run in changed.contains { run.contains($0) } }.count
        #expect(runs.count >= 200 && Double(found) >= 0.95 * Double(runs.count), "\(found) of \(runs.count)")
    }

    /// C17: the measure step reads `isCancelled` before each block and throws `.cancelled` at the
    /// first true: a 3 s span (three blocks) with a cancel at the second call reads one block. With
    /// no cancel it reads each block. Fail: a measure with no cancel point.
    @Test func measureStopsAtCancel() throws {
        let fixture = try RenderFixture()
        try fixture.package.addFile("f1", channels: [clippedVowel(level: 0.999, seconds: 3)])
        let url = fixture.package.url.appending(path: "\(clipsFolderName)/f1.wav")
        let source = try AVAudioFile(forReading: url)
        let descriptor = open(url.path, O_RDONLY)
        defer { close(descriptor) }
        func measure(cancelAt: Int) throws(ClipRenderError) -> Int {
            var calls = 0
            _ = try repairSetup(
                span: 0..<144_000, of: source, descriptor: descriptor, treatment: Treatment(.declip(.standard)),
                file: "f1.wav", stem: "f1 RP", readFault: nil,
                isCancelled: {
                    calls += 1
                    return calls >= cancelAt
                })
            return calls
        }

        #expect(try measure(cancelAt: .max) >= 3, "each block reads `isCancelled`")
        #expect(throws: ClipRenderError.cancelled) { try measure(cancelAt: 2) }
    }

    /// C18: the de-clip measure of a float source refuses an infinite sample with `.nonFiniteSample`
    /// and does not trap, and a finite sample of 2^41 (past the Int64 range on the 24-bit grid)
    /// gives the 24-bit depth. Fail: `Int64(abs(code))`, which traps on both.
    @Test func measureRefusesAnInfiniteSample() throws {
        let fixture = try RenderFixture()
        func measure(_ value: Float, name: String) throws -> RepairSetup {
            var samples = seededNoise(frames: 48_000, level: 0.1, seed: 33)
            samples[20_000] = value
            let url = fixture.package.url.appending(path: "\(clipsFolderName)/\(name).wav")
            try writeSource(url, .wavFloat, rate: 48_000, channels: [samples])
            let source = try AVAudioFile(forReading: url)
            let descriptor = open(url.path, O_RDONLY)
            defer { close(descriptor) }
            return try repairSetup(
                span: 0..<48_000, of: source, descriptor: descriptor, treatment: Treatment(.declip(.standard)),
                file: "\(name).wav", stem: "\(name) RP", readFault: nil, isCancelled: { false })
        }

        #expect(throws: ClipRenderError.nonFiniteSample(file: "inf.wav")) { try measure(.infinity, name: "inf") }
        #expect(try measure(0x1p41, name: "big").carriedBits == 24)
    }

    /// C18: a stage that gives one NaN makes the render throw `.nonFiniteSample` before the write,
    /// and `Clips/` keeps its files; the same stage with no NaN renders. Fail: the 0054 render,
    /// which writes the NaN.
    @Test func nonFiniteBlockIsRefused() throws {
        let fixture = try RenderFixture()
        let noise = seededNoise(frames: 96_000, level: 0.1, seed: 31)
        try fixture.add("f1", [noise], track: "t1", clips: [("c1", 0, noise.count)])
        let before = try fixture.hashes()

        #expect(throws: ClipRenderError.nonFiniteSample(file: "Clips/f1 RP.wav")) {
            try repair(fixture, ["c1"], Treatment(.rumble(.standard)), addedStage: TestStage(nan: 70_000))
        }
        #expect(try fixture.hashes() == before)
        let outcome = try repair(fixture, ["c1"], Treatment(.rumble(.standard)), addedStage: TestStage())
        #expect(outcome.made.map(\.lastPathComponent) == ["f1 RP.wav"])
    }

    /// C19: on a 22,050 Hz package a de-ess at 9,923 Hz (0.45 x the rate or over) is refused with
    /// the limit 9,922 Hz before any read, with a de-clip that would read the span, and `Clips/`
    /// keeps its files; 9,922 Hz renders. Fail: no bound (the 9,923 Hz render writes a file), and
    /// the corner check after the measure (a read before the refusal).
    @Test func cornerOverTheLimitWritesNothing() throws {
        let fixture = try RenderFixture(rate: 22_050)
        let noise = seededNoise(frames: 44_100, level: 0.1, seed: 32)
        try fixture.add("f1", [noise], track: "t1", clips: [("c1", 0, noise.count)])
        let before = try fixture.hashes()
        let treatment = { (hertz: Int) throws -> Treatment in
            let deess = try #require(DeEss(hertz: hertz, decibels: 10))
            return try #require(Treatment([.declip(.standard), .deess(deess)]))
        }
        let fault = ReadFault(stem: "f1 RP", block: 0) { Issue.record("a read before the refusal") }

        #expect(throws: ClipRenderError.cornerTooHigh(hertz: 9_923, limit: .hertz(9_922))) {
            try repair(fixture, ["c1"], try treatment(9_923), readFault: fault)
        }
        #expect(try fixture.hashes() == before)
        #expect(try repair(fixture, ["c1"], try treatment(9_922)).made.count == 1)
    }

    /// C19: the corner check names the highest whole Hz under 0.45 x the rate, or, when that is
    /// under the range of the type, the lowest session rate that takes the effect: a de-ess at
    /// 2,000 Hz passes at 4,445 Hz and names 4,445 Hz at 4,444 Hz; a rumble at 45 Hz at 100 Hz
    /// names 44 Hz, and at 44 Hz names the rate 45 Hz.
    @Test func cornerCheckNamesTheBound() throws {
        let deess = Treatment(.deess(try #require(DeEss(hertz: 2_000, decibels: 10))))
        let rumble = Treatment(.rumble(try #require(Rumble(hertz: 45))))

        #expect(throws: Never.self) { try RepairSetup.check(deess, rate: 4_445) }
        #expect(throws: ClipRenderError.cornerTooHigh(hertz: 2_000, limit: .lowestRate(4_445))) {
            try RepairSetup.check(deess, rate: 4_444)
        }
        #expect(throws: ClipRenderError.cornerTooHigh(hertz: 45, limit: .hertz(44))) {
            try RepairSetup.check(rumble, rate: 100)
        }
        #expect(throws: ClipRenderError.cornerTooHigh(hertz: 45, limit: .lowestRate(45))) {
            try RepairSetup.check(rumble, rate: 44)
        }
        #expect(throws: Never.self) { try RepairSetup.check(Treatment(.declip(.standard)), rate: 8_000) }
    }

    /// C1: the render form of the 80 Hz high-pass: sines of 0.5 in files, the RMS of the second
    /// second: -3.01 dB +-0.05 at 80 Hz, -12.0 dB or less at 40 Hz, within 0.05 dB at 300 Hz and
    /// 1 kHz.
    @Test func rumbleResponseOnAFile() throws {
        let fixture = try RenderFixture()
        let tones: [ClipID: Double] = ["c80": 80, "c40": 40, "c300": 300, "c1000": 1_000]
        for (index, (clip, hertz)) in tones.sorted(by: { $0.value < $1.value }).enumerated() {
            let sine = (0..<96_000).map { Float(0.5 * sin(2 * .pi * hertz * Double($0) / 48_000)) }
            try fixture.add(FileID("f\(index)"), [sine], track: TrackID("t\(index)"), clips: [(clip, 0, sine.count)])
        }

        let outcome = try repair(fixture, Array(tones.keys), Treatment(.rumble(.standard)))

        var gains: [Double: Double] = [:]
        for (clip, hertz) in tones {
            let output = try fixture.samples(try #require(outcome.session.clip(clip)?.clip.file), in: outcome.session)
            let sine = (0..<96_000).map { Float(0.5 * sin(2 * .pi * hertz * Double($0) / 48_000)) }
            gains[hertz] = rmsDecibels(output, from: 48_000) - rmsDecibels(sine, from: 48_000)
        }
        let label = "\(gains.sorted { $0.key < $1.key })"
        #expect(abs(gains[80, default: 0] + 3.01) <= 0.05, "80 Hz; \(label)")
        #expect(gains[40, default: 0] <= -12.0, "40 Hz; \(label)")
        for hertz in [300.0, 1_000] { #expect(abs(gains[hertz, default: 99]) <= 0.05, "\(hertz) Hz; \(label)") }
    }
}
