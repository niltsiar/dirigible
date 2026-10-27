import AVFoundation
import CryptoKit
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// Gaussian noise at `level` (RMS, linear) from a fixed seed, so each run gives the same samples.
func seededNoise(frames: Int, level: Double, seed: UInt64) -> [Float] {
    var state = seed
    func uniform() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return (Double(state >> 11) + 0.5) / Double(1 << 53)
    }
    return (0..<frames).map { _ in Float(level * sqrt(-2 * log(uniform())) * cos(2 * .pi * uniform())) }
}

/// The RMS of `samples` in dB, from `from`.
func rmsDecibels(_ samples: [Float], from: Int = 0) -> Double {
    let tail = samples[from...]
    let power = tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, tail.count))
    return 10 * log10(power)
}

/// A spoken sentence from `say`, at the rate `rate`, scaled to the peak `peak`. The file goes in
/// the temp folder of the test; no recording is in git.
func spokenVoice(rate: Int, peak: Float, in folder: URL) throws -> [Float] {
    let caf = folder.appending(path: "voice.caf")
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/say")
    process.arguments = [
        "-o", caf.path, "--data-format=LEF32@\(rate)",
        "The noise reduction keeps the voice and lowers the hiss of the room behind it.",
    ]
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    let samples = try readAudio(caf).samples
    let top = samples.map(abs).max() ?? 1
    return samples.map { $0 * peak / top }
}

/// The voice of `spokenVoice` 18 dB hotter and clipped two 24-bit steps under full scale: the
/// unit rebuilds the clipped peaks over full scale, so its render needs a second pass.
func hotVoice(in folder: URL) throws -> [Float] {
    let top: Float = 0x1.fffffcp-1 - 0x1p-23
    return try spokenVoice(rate: 48_000, peak: 8 * top, in: folder).map { min(max($0, -top), top) }
}

/// A package with one track for each file, its clips, and the render of `renderClips`.
struct RenderFixture {
    let package: MixPackage

    init(rate: Int = 48_000) throws { package = try MixPackage(sampleRate: rate) }

    /// Adds the file `file` with `channels`, and the track `track` with `role` and each clip (ID,
    /// offset, length) at the timeline frame of its offset.
    func add(
        _ file: FileID, _ channels: [[Float]], track: TrackID, role: Track.Role? = nil,
        clips: [(ClipID, Int, Int)]
    ) throws {
        try package.addFile(file, channels: channels)
        try package.session.addTrack(track, name: track.rawValue, layout: channels.count == 1 ? .mono : .stereo)
        if let role { try package.session.setRole(role, tracks: [track]) }
        for (id, offset, length) in clips {
            try package.session.place(
                Clip(id: id, file: file, start: Frames(offset), offset: Frames(offset), length: Frames(length)),
                on: track)
        }
    }

    func render(
        _ clips: [ClipID], of session: Session? = nil, freeBytes: Int64 = .max,
        component: (Int) -> AudioComponentDescription = { _ in .soundIsolation }, readFault: ReadFault? = nil,
        isDownloaded: (URL) -> Bool = { _ in true }, progress: @escaping (Double) -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { false }
    ) throws(ClipRenderError) -> ClipRenderOutcome {
        try renderClips(
            [(clips, Treatment(.noise(.standard)))], of: session ?? package.session, in: package.url,
            freeBytes: { freeBytes }, component: component, readFault: readFault, isDownloaded: isDownloaded,
            progress: progress, isCancelled: isCancelled)
    }

    /// The names in `Clips/`, temp files too.
    func listing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: package.url.appending(path: clipsFolderName).path).sorted()
    }

    /// The SHA-256 of each item in `Clips/`, temp files too, by name.
    func hashes() throws -> [String: SHA256.Digest] {
        let clips = package.url.appending(path: clipsFolderName)
        var hashes: [String: SHA256.Digest] = [:]
        for name in try listing() {
            hashes[name] = SHA256.hash(
                data: FileManager.default.contents(atPath: clips.appending(path: name).path) ?? Data())
        }
        return hashes
    }

    /// The interleaved samples of the WAV at `name` in `Clips/`.
    func samples(_ name: String) throws -> [Float] {
        try readAudio(package.url.appending(path: "\(clipsFolderName)/\(name)")).samples
    }

    /// The interleaved samples of the WAV of `file` in `session`.
    func samples(_ file: FileID, in session: Session) throws -> [Float] {
        try samples(try #require(session.files[file]?.path))
    }

    /// The span `frames` of the source file `file` as it reads back, interleaved.
    func source(_ file: FileID, _ frames: Range<Int>, channels: Int) throws -> [Float] {
        Array(try samples("\(file.rawValue).wav")[(frames.lowerBound * channels)..<(frames.upperBound * channels)])
    }

    /// Renders the frames `span` of the file `file` through one chain with a raw wet value and a
    /// scale into `<name>.wav`, and gives its samples, interleaved, and its peak.
    func chainRender(
        _ file: FileID, span: Range<Int>, wet: Float, scale: Float = 1, name: String
    ) throws -> (samples: [Float], peak: Float) {
        let url = package.url.appending(path: "\(clipsFolderName)/\(file.rawValue).wav")
        let source = try AVAudioFile(forReading: url)
        let descriptor = open(url.path, O_RDONLY)
        defer { close(descriptor) }
        let chain = try EffectChain(
            wetDryMixPercent: wet, scale: scale, rate: source.fileFormat.sampleRate,
            channels: Int(source.fileFormat.channelCount), component: .soundIsolation)
        let out = package.url.appending(path: "\(clipsFolderName)/\(name).wav")
        let writer = try ClipWriter(url: out, file: name, format: source.processingFormat)
        let result = try chain.render(
            source, descriptor: descriptor, span: Int64(span.lowerBound)..<Int64(span.upperBound), into: writer,
            file: file.rawValue, wav: name, stem: name, readFault: nil, isCancelled: { false }, rendered: { _ in })
        #expect(result.length == span.count)
        return (try samples("\(name).wav"), result.peak)
    }
}

/// The audio of a clip render through AUSoundIsolation (decision 0054): the alignment, the spans,
/// the runs, the peak rule, the amount, and the joint stereo.
struct EffectRenderTests {
    /// C3: at wet 0 the new file equals the source span within 1e-6, mono and stereo, at 48 and
    /// 44.1 kHz. The span is longer than two blocks, so a feed that runs dry shows.
    @Test(arguments: [(1, 48_000), (2, 48_000), (1, 44_100), (2, 44_100)])
    func wetZeroNullsTheSource(channels: Int, rate: Int) throws {
        let fixture = try RenderFixture(rate: rate)
        let frames = 5 * rate
        let sides = (0..<channels).map { seededNoise(frames: frames, level: 0.1, seed: UInt64(1 + $0)) }
        try fixture.package.addFile("f1", channels: sides)
        let span = (rate / 2)..<(frames - rate / 2)

        let (rendered, _) = try fixture.chainRender("f1", span: span, wet: 0, name: "out")

        let source = try fixture.source("f1", span, channels: channels)
        try #require(rendered.count == source.count)
        #expect(maxError(rendered, source) <= 1e-6, "channels \(channels) at \(rate) Hz")
    }

    /// C3: two far clips of one file are two runs, each through its own chain, and both null.
    @Test func twoRunsOfOneFileNull() throws {
        let fixture = try RenderFixture()
        let frames = 30 * 48_000
        try fixture.package.addFile("f1", channels: [seededNoise(frames: frames, level: 0.1, seed: 3)])

        for (index, span) in [48_000..<240_000, 1_200_000..<1_392_000].enumerated() {
            let (rendered, _) = try fixture.chainRender("f1", span: span, wet: 0, name: "run\(index)")
            #expect(maxError(rendered, try fixture.source("f1", span, channels: 1)) <= 1e-6, "run \(index)")
        }
    }

    /// C3: the last 0.5 s of the span is in the file: the tail is flushed past the unit latency.
    @Test func tailIsFlushed() throws {
        let fixture = try RenderFixture()
        try fixture.package.addFile("f1", channels: [seededNoise(frames: 240_000, level: 0.1, seed: 4)])

        let (rendered, _) = try fixture.chainRender("f1", span: 0..<240_000, wet: 0, name: "out")

        let tail = 216_000..<240_000
        let source = try fixture.source("f1", tail, channels: 1)
        #expect(maxError(Array(rendered[tail]), source) <= 1e-6)
        #expect(rmsDecibels(Array(rendered[tail])) > -30, "the tail holds the noise, not silence")
    }

    /// A short last pull keeps the tail: 96,000 frames and the latency end in a pull of 401, and at
    /// 12 dB the last 4096 frames of the span equal the same frames of a span 4096 frames longer,
    /// over a source that is silent past the span.
    @Test func shortLastPullKeepsTheTail() throws {
        let fixture = try RenderFixture()
        let voice = try spokenVoice(rate: 48_000, peak: 0.5, in: fixture.package.folder.url).prefix(96_000)
        try fixture.package.addFile("f1", channels: [Array(voice) + [Float](repeating: 0, count: 8192)])
        let wet = NoiseReduction.standard.wetDryMixPercent

        let short = try fixture.chainRender("f1", span: 0..<96_000, wet: wet, name: "short")
        let long = try fixture.chainRender("f1", span: 0..<100_096, wet: wet, name: "long")

        let tail = 91_904..<96_000
        #expect(maxError(Array(short.samples[tail]), Array(long.samples[tail])) <= 1e-6)
        #expect(rmsDecibels(Array(short.samples[tail])) > -60, "the tail holds the voice")
    }

    /// C2: one 10 s clip at 25 s of a 60 s file writes 30 s from 15 s, not the whole file, and the
    /// new offset is 10 s. At offset 0 the handle stops at the file start.
    @Test func writesTheRunSpan() throws {
        let fixture = try RenderFixture()
        try fixture.add(
            "f1", [seededNoise(frames: 2_880_000, level: 0.01, seed: 5)], track: "t1",
            clips: [("c1", 1_200_000, 480_000), ("c0", 0, 480_000)])

        let one = try fixture.render(["c1"])
        let moved = try #require(one.session.clip("c1")?.clip)
        #expect(one.session.files[moved.file]?.length == Frames(1_440_000), "fail value 2,880,000")
        #expect(moved.offset == Frames(480_000))
        #expect(one.clips == [RenderedClip(clip: "c1", file: moved.file)])

        let capped = try fixture.render(["c0"])
        let start = try #require(capped.session.clip("c0")?.clip)
        #expect(capped.session.files[start.file]?.length == Frames(960_000))
        #expect(start.offset == .zero)
    }

    /// C4 at the ends of the range: 6 dB and 30 dB cut noise with no voice by the amount within
    /// 1 dB. The raw unit gives 6.00 and 30.00 (probe gate1-a4-a7).
    @Test(arguments: [6, 30])
    func reductionAtTheEndsOfTheRange(decibels: Int) throws {
        let fixture = try RenderFixture()
        let noise = seededNoise(frames: 480_000, level: 0.0562, seed: 8)
        try fixture.add("noise", [noise], track: "t1", clips: [("n", 0, noise.count)])
        let amount = try #require(NoiseReduction(decibels: decibels))

        let outcome = try renderClips(
            [(["n"], Treatment(.noise(amount)))], of: fixture.package.session, in: fixture.package.url,
            freeBytes: { .max }, isDownloaded: { _ in true })

        let out = try fixture.samples(try #require(outcome.session.clip("n")?.clip.file), in: outcome.session)
        let cut = rmsDecibels(noise, from: 48_000) - rmsDecibels(out, from: 48_000)
        #expect(abs(cut - Double(decibels)) <= 1, "noise cut \(cut) dB at \(decibels) dB")
    }

    /// C2: two clips 5 s apart share one file; 60 s apart they get two, `f1 NR` and `f1 NR 2`.
    @Test func nearClipsShareAFile() throws {
        let fixture = try RenderFixture()
        try fixture.add(
            "f1", [seededNoise(frames: 2_400_000, level: 0.01, seed: 6)], track: "t1",
            clips: [("a", 720_000, 48_000), ("b", 1_008_000, 48_000)])

        let outcome = try fixture.render(["a", "b"])

        #expect(outcome.made.map(\.lastPathComponent) == ["f1 NR.wav"])
        #expect(outcome.session.clip("a")?.clip.file == outcome.session.clip("b")?.clip.file)
    }

    @Test func farClipsGetTwoFiles() throws {
        let fixture = try RenderFixture()
        try fixture.add(
            "f1", [seededNoise(frames: 4_800_000, level: 0.01, seed: 7)], track: "t1",
            clips: [("a", 528_000, 48_000), ("b", 3_408_000, 48_000)])

        let outcome = try fixture.render(["a", "b"])

        #expect(outcome.made.map(\.lastPathComponent) == ["f1 NR.wav", "f1 NR 2.wav"])
        #expect(outcome.clips.map(\.clip) == ["a", "b"])
        #expect(Set(outcome.clips.map(\.file)).count == 2)
    }

    /// C2b: a run over full scale renders again at the scale of `fullScaleRepair`: the second pass
    /// is the first times the scale within 1e-6, no sample is at an end code, and the clip gain is
    /// the dB of the scale. A source at -0.1 dBFS with a gain stage of +0.6 dB peaks at +0.5 dBFS.
    @Test func overFullScaleScalesGain() throws {
        let fixture = try RenderFixture()
        let level = Float(pow(10, -0.1 / 20))
        let wave = (0..<96_000).map { level * Float(sin(2 * Double.pi * 441 * Double($0) / 48_000)) }
        try fixture.package.addFile("f1", channels: [wave])
        let gain = Float(pow(10, 0.6 / 20))

        let first = try fixture.chainRender("f1", span: 0..<96_000, wet: 0, scale: gain, name: "pass1")
        let scale = try #require(fullScaleRepair(first.peak))
        let second = try fixture.chainRender("f1", span: 0..<96_000, wet: 0, scale: gain * scale, name: "pass2")

        #expect(abs(20 * log10(Double(first.peak)) - 0.5) < 0.01, "the render peak is +0.5 dBFS")
        let expected = try fixture.source("f1", 0..<96_000, channels: 1).map { $0 * gain * scale }
        #expect(maxError(second.samples, expected) <= 1e-6)
        #expect(second.samples.allSatisfy { $0 > -1 && $0 < 0x1.fffffcp-1 }, "a sample at an end code")
        #expect(abs(-20 * log10(Double(scale)) - 0.5) < 0.01, "the clip gain is +0.5 dB")
    }

    /// C2b: the real unit at 12 dB on a hot voice gives no sample at a 24-bit end code; a run over
    /// full scale gets a clip gain of the dB of its scale.
    @Test func overFullScaleOnTheRealUnit() throws {
        let fixture = try RenderFixture()
        let voice = try hotVoice(in: fixture.package.folder.url)
        try fixture.add("f1", [voice], track: "t1", clips: [("c1", 0, voice.count)])

        let outcome = try fixture.render(["c1"])

        let clip = try #require(outcome.session.clip("c1")?.clip)
        let samples = try fixture.samples(clip.file, in: outcome.session)
        #expect(samples.allSatisfy { $0 > -1 && $0 < 0x1.fffffcp-1 }, "a sample at an end code")
        #expect(clip.gain.dB > 0, "the render peaks over full scale, so a second pass runs")
    }

    /// C4: at 12 dB, noise with no voice goes down 11 to 13 dB, and a voice keeps its level within
    /// 1 dB, at 48 and 44.1 kHz.
    @Test(arguments: [48_000, 44_100])
    func twelveDecibelsOfReduction(rate: Int) throws {
        let fixture = try RenderFixture(rate: rate)
        let noise = seededNoise(frames: 10 * rate, level: 0.0562, seed: 8)
        let voice = try spokenVoice(rate: rate, peak: 0.5, in: fixture.package.folder.url)
        try fixture.add("noise", [noise], track: "t1", clips: [("n", 0, noise.count)])
        try fixture.add("voice", [voice], track: "t2", clips: [("v", 0, voice.count)])

        let outcome = try fixture.render(["n", "v"])

        let noiseOut = try fixture.samples(try #require(outcome.session.clip("n")?.clip.file), in: outcome.session)
        let voiceOut = try fixture.samples(try #require(outcome.session.clip("v")?.clip.file), in: outcome.session)
        let cut = rmsDecibels(noise, from: rate) - rmsDecibels(noiseOut, from: rate)
        let change = rmsDecibels(voiceOut) - rmsDecibels(voice)
        #expect(cut >= 11 && cut <= 13, "noise cut \(cut) dB; fail value 6.0")
        #expect(abs(change) <= 1, "voice change \(change) dB; fail value 2.0")
    }

    /// C5: stereo is joint: equal channels stay equal after the first unit latency, and a silent
    /// channel stays silent. The unit itself makes up to 0.0212 (48 kHz) and 0.0414 (44.1 kHz) of
    /// L-R in its first render call, inside the latency; a pull of 8192 frames gives 0.23 past it.
    @Test(arguments: [48_000, 44_100])
    func stereoStaysJoint(rate: Int) throws {
        let fixture = try RenderFixture(rate: rate)
        let noisy = try spokenVoice(rate: rate, peak: 0.4, in: fixture.package.folder.url)
            .enumerated().map { $1 + 0.02 * Float(sin(Double($0) * 0.37)) }
        try fixture.add("equal", [noisy, noisy], track: "t1", clips: [("e", 0, noisy.count)])
        try fixture.add(
            "silent", [noisy, [Float](repeating: 0, count: noisy.count)], track: "t2", clips: [("s", 0, noisy.count)])

        let outcome = try fixture.render(["e", "s"])

        let equal = try fixture.samples(try #require(outcome.session.clip("e")?.clip.file), in: outcome.session)
        let silent = try fixture.samples(try #require(outcome.session.clip("s")?.clip.file), in: outcome.session)
        let gaps: [Float] = stride(from: 0, to: equal.count, by: 2).map { abs(equal[$0] - equal[$0 + 1]) }
        let right = stride(from: 1, to: silent.count, by: 2).map { abs(silent[$0]) }.max() ?? 1
        let latency = try EffectChain(
            wetDryMixPercent: 0, scale: 1, rate: Double(rate), channels: 2, component: .soundIsolation
        ).latency
        let worst = gaps.indices.max { gaps[$0] < gaps[$1] } ?? 0
        #expect((gaps[latency...].max() ?? 1) <= 1e-6, "worst frame \(worst) of \(gaps.count)")
        #expect((gaps[..<latency].max() ?? 1) <= 0.05, "worst frame \(worst); fail value 0.23")
        #expect(right <= 1e-6)
        #expect(rmsDecibels(equal) > -40, "the render keeps the voice")
    }
}
