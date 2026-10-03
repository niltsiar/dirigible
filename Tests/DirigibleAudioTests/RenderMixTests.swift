import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The chunked render of `dirigible render` (timeline-playback criterion 18, plan gate 1 item
/// 5). Tolerance: ± 1e-6 per sample (no gain).
struct RenderMixTests {
    /// Reads a float CAF as two channel arrays.
    static func read(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return channels(buffer)
    }

    /// Mono track `t1` with clip `c1` (ramp frames 0..<20 000) at 500, and stereo track `t2` with
    /// clip `c2` at 3000.
    static func package() throws -> MixPackage {
        let package = try MixPackage()
        try package.addFile("f1", channels: [ramp(frames: 20_000)])
        try package.addFile("f2", channels: [ramp(frames: 20_000, channel: 1), ramp(frames: 20_000, channel: 2)])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 500, offset: 0, length: 20_000)
        try package.addTrack("t2", layout: .stereo, clip: "c2", file: "f2", start: 3000, offset: 0, length: 20_000)
        return package
    }

    @Test func chunksJoinWithNoSeam() throws {
        let package = try Self.package()
        let out = package.folder.url.appending(path: "mix.caf")

        let faults = try exportMix(
            package.session, source: #require(ExportSource(range: 0..<9600)), options: .render, to: out,
            package: { package.url }, chunk: 4096
        ).faults

        #expect(faults == [:])
        let rendered = try Self.read(out)
        for (a, b) in zip(rendered, try package.mix(0..<9600)) { #expect(maxError(a, b) <= 1e-6) }
        #expect(rendered.map(\.count) == [9600, 9600])
    }

    /// Fades C10: a render in chunks of 100 frames, with seams inside both fades, equals one render.
    @Test func fadesJoinWithNoSeam() throws {
        let package = try fadedPackage()
        let whole = try package.mix(0..<7000)
        let reader = package.reader()
        var chunks: [[Float]] = [[], []]
        for start in stride(from: 0, to: 7000, by: 100) {
            let part = try package.render(reader, Frames(start)..<Frames(start + 100))
            for channel in 0..<2 { chunks[channel] += part[channel] }
        }
        for (a, b) in zip(chunks, whole) { #expect(maxError(a, b) <= 1e-6, "the chunks equal one render") }
    }
}
