import AVFoundation
import DirigibleAudio
import DirigibleCore
import Foundation
import Testing

/// `dirigible export --loudness` (run 9a criterion 18, decision 0032).
struct ExportLoudnessCommandTests {
    /// One stereo track with a clip of 20 s of a 1 kHz sine at `dBFS` (-infinity: silence).
    static func package(dBFS: Double) throws -> TemporaryPackage {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .stereo, length: 960_000))
        try session.addTrack("t1", name: "Host", layout: .stereo)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 960_000), on: "t1")
        let package = try TemporaryPackage(session)
        try LoudnessCommandTests.writeWAV(package.url.appending(path: "Clips/f1.wav"), seconds: 20, dBFS: dBFS)
        return package
    }

    /// The integrated loudness of an audio file.
    static func loudness(_ url: URL) throws -> LUFS? {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        var meter = try #require(LoudnessMeter(sampleRate: Int(file.processingFormat.sampleRate), layout: .stereo))
        meter.feed(buffer)
        return meter.result().integrated
    }

    @Test func theTargetIsReported() async throws {
        let package = try Self.package(dBFS: -30)
        let out = package.folder.appending(path: "ep.wav")

        let result = try await package.run("export", "PKG", "--out", out.path, "--loudness", "podcast")

        let line = "loudness -16.0 LUFS, true peak -16.0 dBTP, gain +14.0 dB\n"
        #expect(result == CLIResult(status: 0, stdout: line, stderr: ""), "\(result)")
        let back = try Self.loudness(out)?.value ?? .nan
        #expect(abs(back - -16) <= 0.1, "the read-back: \(back) LUFS")
    }

    @Test func anUnknownTargetIsRefused() async throws {
        let package = try Self.package(dBFS: -30)
        let out = package.folder.appending(path: "ep.wav")

        let result = try await package.run("export", "PKG", "--out", out.path, "--loudness", "loud")

        #expect(result.status == 64 && result.stderr.contains("podcast, speech, ebu, or atsc"), "\(result)")
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func aSilentPackageHasNoMeasurement() async throws {
        let package = try Self.package(dBFS: -.infinity)
        let out = package.folder.appending(path: "ep.wav")

        let result = try await package.run("export", "PKG", "--out", out.path, "--loudness", "podcast")

        let line = "loudness none, true peak none, gain +0.0 dB\n"
        #expect(result == CLIResult(status: 0, stdout: line, stderr: ""), "\(result)")
    }
}
