import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// The preview of a clip render (decision 0054): the clip, the window and its source, the levels,
/// the loop of the Result or the Removed Sound, and the thread of the render. The engine renders
/// offline, and each noise render runs AUSoundIsolation.
struct EffectPreviewTests {
    let twelve = ClipRenderRequest(Treatment(.noise(.standard)))

    func amount(_ decibels: Int) -> ClipRenderRequest {
        ClipRenderRequest(Treatment(.noise(NoiseReduction(decibels: decibels)!)))
    }

    func request(_ effects: [Effect]) -> ClipRenderRequest { ClipRenderRequest(Treatment(effects)!) }

    /// The 26 s mono noise file "f1" and the clip "c1" of 3 s at 12 s on "t1".
    func fixture() throws -> RenderFixture {
        let fixture = try RenderFixture()
        try fixture.add(
            "f1", [seededNoise(frames: 1_248_000, level: 0.05, seed: 7)], track: "t1",
            clips: [("c1", 576_000, 144_000)])
        return fixture
    }

    /// The session after a render of c1 for each request of `requests`, one level each.
    func rendered(_ fixture: RenderFixture, _ requests: [ClipRenderRequest]) throws -> Session {
        var session = fixture.package.session
        for request in requests {
            session = try renderRequest(
                ["c1"], request: request, of: session, in: fixture.package.url, freeBytes: { .max },
                isDownloaded: { _ in true }
            ).session
        }
        return session
    }

    /// A preview of the package of `fixture` that renders offline.
    func engine(_ fixture: RenderFixture) -> EffectPreview {
        let url = fixture.package.url
        return EffectPreview(package: { url }, output: .offline, rate: 48_000, ended: { _ in })
    }

    /// C19: the Removed Sound loop is the aligned source minus the Result loop within 1e-4, frame for
    /// frame from the first pulled frame, and a mono window plays in both channels.
    @Test func removedSoundIsTheDifference() async throws {
        let fixture = try fixture()
        let session = fixture.package.session
        let window = try previewWindow(of: "c1", request: twelve, playhead: .zero, in: session)
        let preview = engine(fixture)

        preview.supersede(1)
        #expect(try await preview.play(window, of: session, listen: .result, number: 1))
        let result = await preview.renderOffline(frames: 144_000)
        preview.supersede(2)
        #expect(try await preview.play(window, of: session, listen: .removedSound, number: 2))
        let removed = await preview.renderOffline(frames: 144_000)

        let source = try fixture.source("f1", 576_000..<720_000, channels: 1)
        #expect(maxError(removed[0], zip(source, result[0]).map { $0 - $1 }) <= 1e-4)
        #expect(maxError(removed[1], removed[0]) == 0 && maxError(result[1], result[0]) == 0)
        #expect(maxError(result[0], source) > 1e-3, "the Result is the source")
    }

    /// C19: on a clip rendered at 12 dB, a request of 20 dB reads the origin source at the origin
    /// offset, not the rendered file, so the preview does not stack.
    @Test func previewReadsTheLevelSource() throws {
        let fixture = try fixture()
        let session = try rendered(fixture, [twelve])
        try #require(session.clip("c1")?.clip.file != "f1")

        let window = try previewWindow(of: "c1", request: amount(20), playhead: .zero, in: session)

        #expect(window == PreviewWindow(file: "f1", span: 528_000..<720_000, leadIn: 48_000, levels: [amount(20)]))
    }

    /// C19, plan gate 4 item 10: a request equal to the stored setting reads the level source too;
    /// a stored kind that the request does not name stays in the window levels; and two levels
    /// render through two chains.
    @Test func previewAtTheStoredAmountReadsTheLevelSource() throws {
        let hum50 = request([.hum(.hz50)])
        let hum60 = request([.hum(.hz60)])
        let both = request([.hum(.hz60), .noise(NoiseReduction(decibels: 20)!)])
        let cases: [(stored: [ClipRenderRequest], request: ClipRenderRequest, levels: [ClipRenderRequest])] = [
            ([amount(20)], amount(20), [amount(20)]),
            ([hum50], hum50, [hum50]),
            ([request([.hum(.hz60), .noise(.standard)])], amount(20), [both]),
            ([hum50, twelve], hum60, [hum60, twelve]),
        ]
        for (stored, request, levels) in cases {
            let fixture = try fixture()
            let session = try rendered(fixture, stored)

            let window = try previewWindow(of: "c1", request: request, playhead: .zero, in: session)

            #expect(window == PreviewWindow(file: "f1", span: 528_000..<720_000, leadIn: 48_000, levels: levels))
            guard levels.count == 2 else { continue }
            let url = fixture.package.url
            let two = try renderPreview(window, of: session, in: url, readFault: nil) { false }
            let lowest = PreviewWindow(file: "f1", span: window.span, leadIn: 48_000, levels: [hum60])
            let one = try renderPreview(lowest, of: session, in: url, readFault: nil) { false }
            #expect(two.result[0].count == 144_000 && maxError(two.result[0], one.result[0]) > 1e-3)
        }
    }

    /// C19, plan gate 4 item 8: a music clip first and a voice clip second give the voice clip with
    /// noise on and the music clip with hum alone; a music clip alone with noise gives no clip.
    @Test func previewTakesTheFirstAcceptedClip() throws {
        let fixture = try RenderFixture()
        try fixture.add(
            "f1", [seededNoise(frames: 96_000, level: 0.05, seed: 1)], track: "m", role: .music,
            clips: [("m1", 0, 48_000)])
        try fixture.add(
            "f2", [seededNoise(frames: 96_000, level: 0.05, seed: 2)], track: "v", clips: [("v1", 0, 48_000)])
        let session = fixture.package.session

        #expect(previewClip(["v1", "m1"], treatment: Treatment(.noise(.standard)), in: session) == "v1")
        #expect(previewClip(["v1", "m1"], treatment: Treatment(.hum(.hz50)), in: session) == "m1")
        #expect(previewClip(["m1"], treatment: Treatment(.noise(.standard)), in: session) == nil)
    }

    /// C19: the window starts at the playhead inside the clip, else at the clip start, and the
    /// Result drops the 1 s of lead-in.
    @Test func windowStartsAtThePlayhead() throws {
        let fixture = try fixture()
        let session = fixture.package.session

        let inside = try previewWindow(of: "c1", request: twelve, playhead: 600_000, in: session)
        let outside = try previewWindow(of: "c1", request: twelve, playhead: 900_000, in: session)

        #expect(inside == PreviewWindow(file: "f1", span: 552_000..<720_000, leadIn: 48_000, levels: [twelve]))
        #expect(outside == PreviewWindow(file: "f1", span: 528_000..<720_000, leadIn: 48_000, levels: [twelve]))
        let audio = try renderPreview(inside, of: session, in: fixture.package.url, readFault: nil) { false }
        #expect(audio.result[0].count == 120_000 && audio.removed[0].count == 120_000)
    }

    /// C19, plan gate 4 item 4: a window renders into memory: `Clips/` has the same names after.
    @Test func previewWritesNoFile() async throws {
        let fixture = try fixture()
        let session = try rendered(fixture, [twelve])
        let before = try fixture.listing()
        let preview = engine(fixture)
        let window = try previewWindow(of: "c1", request: amount(20), playhead: .zero, in: session)

        preview.supersede(1)
        #expect(try await preview.play(window, of: session, listen: .result, number: 1))

        #expect(try fixture.listing() == before)
    }

    /// C19: two fast changes give one window, of the last value; the older render ends and changes
    /// nothing.
    @Test func latestDialWins() async throws {
        let fixture = try fixture()
        let session = fixture.package.session
        let windows = try [twelve, amount(20), amount(6)].map {
            try previewWindow(of: "c1", request: $0, playhead: .zero, in: session)
        }
        let preview = engine(fixture)
        preview.supersede(1)
        #expect(try await preview.play(windows[0], of: session, listen: .result, number: 1))

        preview.supersede(2)
        async let older = preview.play(windows[1], of: session, listen: .result, number: 2)
        preview.supersede(3)
        async let newer = preview.play(windows[2], of: session, listen: .result, number: 3)
        let (dropped, shown) = try await (older, newer)

        #expect(!dropped && shown)
        #expect(await preview.windows == 2, "the older change made a window")
        let looped = await preview.renderOffline(frames: 144_000)
        let alone = engine(fixture)
        alone.supersede(1)
        _ = try await alone.play(windows[2], of: session, listen: .result, number: 1)
        #expect(maxError(looped[0], await alone.renderOffline(frames: 144_000)[0]) <= 1e-6)
    }

    /// C19b: the window render runs off the main thread.
    @MainActor
    @Test func windowRendersOffTheMainThread() async throws {
        let fixture = try await StudioSplitTests.make()
        let studio = try await Studio.open(fixture.package.url)
        studio.environment = .test(TestHAL([]))
        let onMain = LockedBox<Bool>()
        studio.environment.clipRenderRead = ReadFault(stem: "f1", block: 0) { onMain.value = Thread.isMainThread }

        try await studio.startEffectPreview(twelve, of: "c1", listen: .result)

        #expect(onMain.value == false && studio.effectPreviewState == .playing)
        await studio.settle()
    }
}
