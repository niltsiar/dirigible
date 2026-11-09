import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The fixtures of probe U1r-b (run 2026-10-14-leveler): one mono 48 kHz file "f1" on track "t1"
/// as clip "c1", with an edit of the session before the ride.
@MainActor
final class RideFixture {
    let package: MixPackage
    let samples: [Float]
    let studio: Studio

    /// With `float`, the file is 32-bit float, so a NaN stays in it. `files` adds to the package
    /// before `edit`.
    init(
        _ samples: [Float], float: Bool = false, edit: (inout Session) throws -> Void = { _ in },
        files: (MixPackage) throws -> Void = { _ in }
    ) async throws {
        package = try MixPackage()
        self.samples = samples
        if float {
            try writeFloat(samples, to: package.url.appending(path: "\(clipsFolderName)/f1.wav"))
            try package.session.addFile(
                AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: Frames(samples.count)))
        } else {
            try package.addFile("f1", channels: [samples])
        }
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: Frames(samples.count))
        try files(package)
        try edit(&package.session)
        try package.session.write(to: package.url)
        studio = try await Studio.open(package.url)
    }

    var frames: Frames { Frames(samples.count) }

    func clip(_ id: ClipID = "c1") throws -> Clip { try #require(studio.session.clip(id)).clip }

    func sessionBytes() throws -> Data { try Data(contentsOf: package.url.appending(path: "session.xml")) }

    @discardableResult
    func ride(_ clips: Set<ClipID> = ["c1"]) async throws -> RideReport {
        try await studio.levelOverTime(clips, agent: nil)
    }
}

/// The noise generator of the probe, so the fixtures equal the probe fixtures.
struct ProbeNoise {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15

    mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(Int64(bitPattern: state) >> 11) / Float(1 << 52)
    }
}

/// Speech-like noise: 300 ms words and 100 ms gaps at -60 dB; `level` in dB at second t.
func rideSpeech(seconds: Double, level: (Double) -> Double) -> [Float] {
    var noise = ProbeNoise()
    return (0..<Int(seconds * 48_000)).map { frame in
        let time = Double(frame) / 48_000
        let inWord = time.truncatingRemainder(dividingBy: 0.4) < 0.3
        return noise.next() * 0.3 * Float(pow(10, (inWord ? level(time) : -60) / 20))
    }
}

/// Music-like noise with no gaps: `level` in dB at second t.
func rideMusic(seconds: Double, level: (Double) -> Double) -> [Float] {
    var noise = ProbeNoise()
    return (0..<Int(seconds * 48_000)).map { frame in
        noise.next() * 0.3 * Float(pow(10, level(Double(frame) / 48_000) / 20))
    }
}

/// The step mean squares of `samples` with a gain in dB on top, read each 48 frames and held.
func heardSteps(_ samples: [Float], gain: (Frames) -> Double) throws -> [Double] {
    var scaled = samples
    var factor: Float = 1
    for frame in scaled.indices {
        if frame % 48 == 0 { factor = Float(pow(10, gain(Frames(frame)) / 20)) }
        scaled[frame] *= factor
    }
    var meter = try #require(LoudnessMeter(sampleRate: 48_000, layout: .mono, keepsSteps: true))
    meter.feed(try pcmBuffer([scaled]))
    return try #require(meter.stepMeanSquares)
}

/// The power mean in LUFS of the steps of seconds `from..<to`.
func heardLoudness(_ steps: [Double], _ from: Double, _ to: Double) -> Double {
    let part = steps[Int(from * 10)..<Int(to * 10)]
    return Loudness.lufs(part.reduce(0, +) / Double(part.count))
}

/// The heard loudness of seconds `from..<to` of `clip` on `samples`: clip gain, envelope, and ride.
func heardLoudness(_ samples: [Float], _ clip: Clip, _ from: Double, _ to: Double) throws -> Double {
    heardLoudness(try heardSteps(samples) { clip.gain.dB + clip.layerGain(at: $0) }, from, to)
}

/// Reading b: the ride layer of the source alone, decimated as the ride writes it.
func sourceRide(_ samples: [Float]) throws -> (dB: [Double], layer: GainEnvelope) {
    let dB = try ride(try heardSteps(samples) { _ in 0 })
    return (dB, GainEnvelope.decimated(dB: dB, first: .zero, stepFrames: rideStepFrames, tolerance: 0.1))
}

/// The file frame of the centre of step `step` of a group that starts at frame 0.
func stepCentre(_ step: Int) -> Frames { Frames((2 * step + 1) * rideStepFrames / 2) }

/// A mono 48 kHz WAV of 32-bit float samples.
private func writeFloat(_ samples: [Float], to url: URL) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    try file.write(from: try pcmBuffer([samples]))
}
