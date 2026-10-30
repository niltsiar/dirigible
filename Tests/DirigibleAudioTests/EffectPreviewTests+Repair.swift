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
