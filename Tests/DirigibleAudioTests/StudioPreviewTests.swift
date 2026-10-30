import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The effect preview of a studio (decision 0054, C19): Play and the preview stop each other, and
/// a take start, an import, and a configuration change of the preview output stop the preview.
/// The Player and the preview render offline (`CaptureEnvironment.test`).
@MainActor
struct StudioPreviewTests {
    let package: MixPackage
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!

    /// Track `t1` on `mic` channel 1, with clip `c1` of 2 s of noise at timeline 0.
    init() throws {
        package = try MixPackage()
        try package.addFile("f1", channels: [seededNoise(frames: 200_000, level: 0.05, seed: 3)])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 96_000)
        try package.session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        try package.session.write(to: package.url)
    }

    /// A studio with the playhead at the start and a running preview of c1 at 12 dB.
    func previewing() async throws -> Studio {
        let studio = try await Studio.open(package.url)
        studio.environment = .test(TestHAL([mic]))
        await studio.perform(.seek(.start))
        try await studio.startEffectPreview(
            ClipRenderRequest(Treatment(.noise(.standard))), of: "c1", among: ["c1"], listen: .result)
        try #require(studio.effectPreviewState == .playing)
        return studio
    }

    @Test func playStopsThePreview() async throws {
        let studio = try await previewing()

        await studio.perform(.playStop)

        #expect(studio.playback != .stopped && studio.effectPreviewState == .stopped)
        await studio.settle()
    }

    @Test func previewStopsPlay() async throws {
        let studio = try await Studio.open(package.url)
        studio.environment = .test(TestHAL([mic]))
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        try #require(studio.playback != .stopped)

        try await studio.startEffectPreview(
            ClipRenderRequest(Treatment(.noise(.standard))), of: "c1", among: ["c1"], listen: .result)

        #expect(studio.playback == .stopped && studio.effectPreviewState == .playing)
        await studio.settle()
    }

    @Test func stopsAtTakeStart() async throws {
        let studio = try await previewing()

        try await studio.startRecording(armed: ["t1"])

        #expect(studio.effectPreviewState == .stopped)
        try await studio.stopRecording()
        await studio.settle()
    }

    @Test func stopsAtImport() async throws {
        let studio = try await previewing()
        let source = package.folder.url.appending(path: "Voice.wav")
        try writeSource(source, .wav16, rate: 48_000, channels: [sine(seconds: 1, rate: 48_000)])

        _ = try await studio.importAudio(source, to: ImportTarget(track: nil, start: 200_000)) { _ in }

        #expect(studio.effectPreviewState == .stopped)
        await studio.settle()
    }

    /// Plan gate 4 item 3: a configuration change of the preview engine stops the preview.
    @Test func stopsAtOutputChange() async throws {
        let studio = try await previewing()

        await studio.effectPreview.engine?.postConfigurationChange()

        await until(limit: .seconds(17), "the output change did not stop the preview") {
            studio.effectPreviewState == .stopped
        }
        await studio.settle()
    }

    /// Code gate 2 item 3: a configuration change while a new window renders stops the preview,
    /// and that render starts no loop (fail: `.playing` after the render ends).
    @Test func outputChangeDuringARenderStops() async throws {
        let studio = try await Studio.open(package.url)
        studio.environment = .test(TestHAL([mic]))
        let (armed, gate) = (LockedBox<Bool>(), Gate(limit: nil))
        defer { gate.open() }
        studio.environment.clipRenderRead = ReadFault(stem: "f1", block: 0) {
            if armed.value == true { gate.waitOnce() }
        }
        await studio.perform(.seek(.start))
        try await studio.startEffectPreview(
            ClipRenderRequest(Treatment(.noise(.standard))), of: "c1", among: ["c1"], listen: .result)
        try #require(studio.effectPreviewState == .playing)
        armed.value = true
        let twenty = ClipRenderRequest(Treatment(.noise(NoiseReduction(decibels: 20)!)))
        let started = Task { try await studio.startEffectPreview(twenty, of: "c1", among: ["c1"], listen: .result) }
        await gate.entered()
        try #require(studio.effectPreviewState == .updating)

        await studio.effectPreview.engine?.postConfigurationChange()
        await until(limit: .seconds(17), "the output change did not stop the preview") {
            studio.effectPreviewState == .stopped
        }
        gate.open()
        try await started.value

        #expect(studio.effectPreviewState == .stopped)
        let engine = try #require(studio.effectPreview.engine)
        let looped = await engine.renderOffline(frames: 48_000)
        #expect(looped.allSatisfy { $0.allSatisfy { $0 == 0 } }, "the new window loops")
        await studio.settle()
    }
}
