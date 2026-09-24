import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The session mix of decision 0016 (timeline-playback criteria 1 to 4): clips at their frames,
/// silence elsewhere. Tolerance: ± 1e-6 per sample with no gain (a 24-bit WAV read into float32
/// is exact).
struct MixTests {
    /// A mono track with one clip: file frames 500..<5300 at timeline 1000.
    func monoClip() throws -> (MixPackage, [Float]) {
        let package = try MixPackage()
        let samples = ramp(frames: 6000)
        try package.addFile("f1", channels: [samples])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 1000, offset: 500, length: 4800)
        return (package, samples)
    }

    @Test func aMonoClipPlaysOnBothChannelsAtItsFrame() throws {
        let (package, samples) = try monoClip()
        let out = try package.mix(0..<6000)
        let clip = Array(samples[500..<5300])
        for channel in out {
            #expect(maxError(Array(channel[1000..<5800]), clip) <= 1e-6)
            #expect(channel[0..<1000].allSatisfy { $0 == 0 })
            #expect(channel[5800..<6000].allSatisfy { $0 == 0 })
        }
    }

    @Test func aRangeWithNoClipIsSilent() throws {
        let (package, _) = try monoClip()
        let out = try package.mix(6000..<9000)
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.count == 3000 && $0.allSatisfy { $0 == 0 } })
    }
}
