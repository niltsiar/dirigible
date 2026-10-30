import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// The preview of the repair effects (decision 0064 D9, criteria C17, C18, and C19): one setup for
/// the render and the preview, so the preview has the scale, the tail, and the guards of the render.
extension EffectPreviewTests {
    /// The mono file "f1" of 14 s of a clipped vowel and the clip "c1" over all of it. The run of the
    /// clip is the whole file.
    func clippedFixture() throws -> (fixture: RenderFixture, source: [Float]) {
        let source = clippedVowel(level: 0.99, seconds: 14)
        let fixture = try RenderFixture()
        try fixture.add("f1", [source], track: "t1", clips: [("c1", 0, source.count)])
        return (fixture, source)
    }

    /// C17: a 10 s window whose end cuts a clipped run equals the same frames of the render to 1e-6,
    /// and its peak is under full scale. Fail: a preview with no scale (the filled run goes over full
    /// scale), and a preview with no tail (the run at the window end stays flat).
    @Test func declipPreviewMatchesTheRender() throws {
        let (fixture, source) = try clippedFixture()
        let session = fixture.package.session
        let end = try #require(
            (500_000..<600_000).first { frame in (frame - 1...frame + 1).allSatisfy { abs(source[$0]) >= 0.98 } })
        let request = ClipRenderRequest(Treatment(.declip(.standard)))

        let window = try previewWindow(
            of: "c1", among: ["c1"], request: request, playhead: Frames(end - 480_000), in: session)
        let audio = try renderPreview(window, of: session, in: fixture.package.url, readFault: nil) { false }

        let outcome = try renderClips(
            [(["c1"], Treatment(.declip(.standard)))], of: session, in: fixture.package.url, freeBytes: { .max },
            isDownloaded: { _ in true })
        let rendered = try fixture.samples(try #require(outcome.made.first).lastPathComponent)
        let expected = Array(rendered[(end - 480_000)..<end])
        #expect(window.tail == 48_000 && audio.result[0].count == 480_000)
        #expect(maxError(audio.result[0], expected) <= 1e-6, "error \(maxError(audio.result[0], expected))")
        #expect((audio.result[0].map { abs($0) }.max() ?? 2) < 1, "the preview peaks at full scale or over")
        #expect(audio.measure?.scale ?? 1 < 1, "the measure has no scale")
    }

    /// D9: the preview of c1 measures the run of the render, which merges c1 and c2 of one file
    /// because their 10 s handles overlap, so its s1 equals the s1 of the render. The 30 s file is
    /// the vowel clipped at 0.3, with 1 s clipped at 0.99 at 19 s, past the handles of c1 alone.
    /// Fail: a preview that measures the run of c1 alone (s1 = 1).
    @Test func previewMeasuresTheRunOfTheRender() throws {
        var source = clippedVowel(level: 0.3, seconds: 30)
        source.replaceSubrange(912_000..<960_000, with: clippedVowel(level: 0.99))
        let fixture = try RenderFixture()
        try fixture.add("f1", [source], track: "t1", clips: [("c1", 0, 384_000), ("c2", 576_000, 384_000)])
        let session = fixture.package.session
        let request = ClipRenderRequest(Treatment(.declip(.standard)))

        let window = try previewWindow(of: "c1", among: ["c1", "c2"], request: request, playhead: .zero, in: session)
        let audio = try renderPreview(window, of: session, in: fixture.package.url, readFault: nil) { false }
        let outcome = try renderRequest(
            ["c1", "c2"], request: request, of: session, in: fixture.package.url, freeBytes: { .max },
            isDownloaded: { _ in true })

        let repair = try #require(outcome.repairs["c1"])
        let scale = try #require(audio.measure?.scale)
        #expect(window.measure?.run == .zero..<Frames(source.count), "run \(String(describing: window.measure?.run))")
        #expect(repair.runs > 0 && repair.levelDrop > 1, "the render fills no run: \(repair)")
        #expect(abs(20 * log10(1 / Double(scale)) - repair.levelDrop) < 1e-3, "s1 \(scale), drop \(repair.levelDrop)")
    }

    /// The Removed Sound of a one-level preview of `request` on c1 at the frame 0, over the mono
    /// file "f1" of `source`, with `kept` as the de-clip measure.
    func removedSound(_ source: [Float], _ request: ClipRenderRequest, kept: RepairMeasure? = nil) throws
        -> [Float]
    {
        let fixture = try RenderFixture()
        try fixture.add("f1", [source], track: "t1", clips: [("c1", 0, source.count)])
        let session = fixture.package.session
        let window = try previewWindow(of: "c1", among: ["c1"], request: request, playhead: .zero, in: session)
        return try renderPreview(window, of: session, in: fixture.package.url, readFault: nil, kept: kept) { false }
            .removed[0]
    }

    /// The root mean square of `samples`.
    func rms(_ samples: [Float]) -> Double {
        (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
    }

    /// Removed Sound holds only what the effects changed, at the input scale: a de-clip with s1 of
    /// 0.7 and no clipped run on a 440 Hz sine of 0.6, and a 10 dB de-ess at 6 kHz of a 2 kHz tone of
    /// 0.3 (the detector stays 19 dB under the full band, so no cut), give a removed loop under 1e-5
    /// and 1e-4 RMS (66 dB under the tone). Fail: the removed loop of the scaled Result (0.3 of the
    /// sine), and the input as the reference of the de-ess (the phase of the split at 2 kHz).
    @Test func removedSoundOfAnEffectThatChangesNothingIsSilent() throws {
        let sine = (0..<96_000).map { Float(0.6 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        let tone = (0..<96_000).map { Float(0.3 * sin(2 * Double.pi * 2_000 * Double($0) / 48_000)) }
        let deess = try #require(DeEss(hertz: 6_000, decibels: 10))
        let measure = RepairMeasure(peaks: [0.6], carriedBits: 24, scale: 0.7, runs: 0)

        let declipped = try removedSound(sine, ClipRenderRequest(Treatment(.declip(.standard))), kept: measure)
        let softened = try removedSound(tone, ClipRenderRequest(Treatment(.deess(deess))))

        #expect(rms(declipped) < 1e-5, "de-clip removed RMS \(rms(declipped))")
        #expect(rms(softened) < 1e-4, "de-ess removed RMS \(rms(softened))")
    }

    /// The Removed Sound of a de-clip of the clipped vowel holds the fills: its energy equals the
    /// energy of the fills of a `DeclipStage` over the same source to 0.1 dB. Fail: the removed loop
    /// of the scaled Result, which adds 1 - s1 of the voice.
    @Test func removedSoundOfADeclipIsTheFill() throws {
        let (fixture, source) = try clippedFixture()
        let session = fixture.package.session
        let request = ClipRenderRequest(Treatment(.declip(.standard)))
        let window = try previewWindow(of: "c1", among: ["c1"], request: request, playhead: .zero, in: session)

        let audio = try renderPreview(window, of: session, in: fixture.package.url, readFault: nil) { false }

        let measure = try #require(audio.measure)
        var stages: [any RenderStage] = [
            DeclipStage(percent: 99, peaks: measure.peaks, carriedBits: measure.carriedBits, rate: 48_000)
        ]
        let filled = Array(stages.process([source], last: true)[0].dropFirst(stages[0].latency))
        let frames = audio.removed[0].count
        let fill = rms(zip(filled.prefix(frames), source.prefix(frames)).map { $0 - $1 })
        let removed = rms(audio.removed[0])
        #expect(measure.runs > 0 && measure.scale < 1 && fill > 1e-3, "\(measure), fill RMS \(fill)")
        #expect(abs(20 * log10(removed / fill)) < 0.1, "removed RMS \(removed), fill RMS \(fill)")
    }

    /// C17 and C19: on a 22,050 Hz package a de-ess at 9,923 Hz is refused with the limit 9,922 Hz,
    /// before the loop starts, and the loop plays nothing. A de-ess at 9,922 Hz plays. Fail: a
    /// preview that clamps the corner or that checks it in `renderClips` only.
    @Test func previewRefusesTheCornerOnA22050Package() async throws {
        let fixture = try RenderFixture(rate: 22_050)
        let noise = seededNoise(frames: 44_100, level: 0.1, seed: 32)
        try fixture.add("f1", [noise], track: "t1", clips: [("c1", 0, noise.count)])
        let session = fixture.package.session
        let url = fixture.package.url
        let preview = EffectPreview(package: { url }, output: .offline, rate: 22_050, ended: { _ in })
        func window(_ hertz: Int) throws -> PreviewWindow {
            let deess = try #require(DeEss(hertz: hertz, decibels: 10))
            let request = ClipRenderRequest(Treatment(.deess(deess)))
            return try previewWindow(of: "c1", among: ["c1"], request: request, playhead: .zero, in: session)
        }

        preview.supersede(1)
        await #expect(throws: StudioError.clipRender(.cornerTooHigh(hertz: 9_923, limit: .hertz(9_922)))) {
            try await preview.play(window(9_923), of: session, listen: .result, number: 1)
        }
        #expect(await preview.renderOffline(frames: 4_800).allSatisfy(\.isEmpty), "the refused window made a loop")
        preview.supersede(2)
        #expect(try await preview.play(window(9_922), of: session, listen: .result, number: 2))
    }

    /// C17: two ticks of the de-ess amount read the span once: the measure is kept for the file, the
    /// run, the de-clip percent, and the rumble corner, and a new de-clip percent measures again.
    /// Fail: a setup for each tick.
    @Test func previewReadsTheSpanOnceForEachSetting() async throws {
        let (fixture, _) = try clippedFixture()
        let session = fixture.package.session
        let url = fixture.package.url
        let preview = EffectPreview(package: { url }, output: .offline, rate: 48_000, ended: { _ in })
        func play(_ number: Int, percent: Int, decibels: Int) async throws {
            let treatment = Treatment([
                .declip(try #require(Declip(percent: percent))),
                .deess(try #require(DeEss(hertz: 6_000, decibels: decibels))),
            ])
            let window = try previewWindow(
                of: "c1", among: ["c1"], request: ClipRenderRequest(try #require(treatment)), playhead: .zero,
                in: session)
            preview.supersede(number)
            #expect(try await preview.play(window, of: session, listen: .result, number: number))
        }

        try await play(1, percent: 95, decibels: 10)
        try await play(2, percent: 95, decibels: 12)
        let ticks = (await preview.windows, await preview.measures)
        try await play(3, percent: 90, decibels: 12)

        #expect(ticks == (2, 1), "windows \(ticks.0), measures \(ticks.1)")
        #expect(await preview.measures == 2, "a new de-clip percent did not measure again")
    }

    /// C17: a rumble step with the de-clip on does not read the clip run again. The first play reads
    /// the run twice for the measure and the window once; the step reads the window only, and its
    /// measure is the one of the first play. A window with no de-clip has no tail. Fail: a rumble
    /// corner in the key of the measure (3 more reads for each step).
    @Test func rumbleStepKeepsTheDeclipMeasure() async throws {
        let (fixture, _) = try clippedFixture()
        let (session, url) = (fixture.package.session, fixture.package.url)
        let reads = LockedBox<Int>()
        let fault = ReadFault(stem: "f1", block: 0) { reads.value = (reads.value ?? 0) + 1 }
        let preview = EffectPreview(package: { url }, output: .offline, rate: 48_000, readFault: fault, ended: { _ in })
        func play(_ number: Int, hertz: Int) async throws -> PreviewWindow {
            let rumble = try #require(Rumble(hertz: hertz))
            let request = ClipRenderRequest(try #require(Treatment([.declip(.standard), .rumble(rumble)])))
            let window = try previewWindow(of: "c1", among: ["c1"], request: request, playhead: .zero, in: session)
            preview.supersede(number)
            #expect(try await preview.play(window, of: session, listen: .result, number: number))
            return window
        }

        let first = try await play(1, hertz: 80)
        let afterFirst = reads.value
        let second = try await play(2, hertz: 120)

        #expect(first.measure == second.measure && first.measure != nil)
        #expect(afterFirst == 3 && reads.value == 4, "reads \(afterFirst ?? -1), then \(reads.value ?? -1)")
        let measures = await preview.measures
        #expect(measures == 1, "measures \(measures)")
        let hum = try previewWindow(
            of: "c1", among: ["c1"], request: request([.rumble(.standard)]), playhead: .zero, in: session)
        #expect(hum.tail == 0 && hum.measure == nil)
    }

    /// C18: a stage that gives a NaN makes the window refuse with `.nonFiniteSample`, and the loop
    /// plays nothing. Fail: a check in `renderClips` only.
    @Test func nonFiniteWindowIsNotPlayed() async throws {
        let fixture = try fixture()
        let session = fixture.package.session
        let url = fixture.package.url
        let preview = EffectPreview(
            package: { url }, output: .offline, rate: 48_000, addedStage: { TestStage(nan: 70_000) },
            ended: { _ in })
        let window = try previewWindow(
            of: "c1", among: ["c1"], request: request([.rumble(.standard)]), playhead: .zero, in: session)

        preview.supersede(1)
        await #expect(throws: StudioError.clipRender(.nonFiniteSample(file: "f1.wav"))) {
            try await preview.play(window, of: session, listen: .result, number: 1)
        }
        #expect(await preview.renderOffline(frames: 4_800).allSatisfy(\.isEmpty), "the window made a loop")
    }
}
