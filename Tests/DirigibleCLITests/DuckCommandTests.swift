import AVFoundation
import DirigibleCore
import Foundation
import Testing

/// `dirigible duck` (decision 0060, C16). Track `v` (dialogue role) plays `speech.wav`: 1 kHz bursts
/// at -20 dBFS RMS from 2 s to 6 s and from 12 s to 16 s over silence, 20 s in all. Track `m`
/// (music role) plays `music.wav`: a 1 kHz tone at -20 dBFS RMS for 20 s.
struct DuckCommandTests {
    let package: TemporaryPackage

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "speech", path: "speech.wav", layout: .mono, length: 960_000))
        try session.addFile(AudioFile(id: "music", path: "music.wav", layout: .mono, length: 960_000))
        try session.addTrack("v", name: "Voice", layout: .mono)
        try session.addTrack("m", name: "Music", layout: .mono)
        try session.place(Clip(id: "cv", file: "speech", start: 0, offset: 0, length: 960_000), on: "v")
        try session.place(Clip(id: "cm", file: "music", start: 0, offset: 0, length: 960_000), on: "m")
        try session.setRole(.dialogue, tracks: ["v"])
        try session.setRole(.music, tracks: ["m"])
        package = try TemporaryPackage(session)
        try Self.write(
            package.url.appending(path: "Clips/speech.wav"), [(2, nil), (4, -20), (6, nil), (4, -20), (4, nil)])
        try Self.write(package.url.appending(path: "Clips/music.wav"), [(20, -20)])
    }

    /// Writes a mono 48 kHz WAV: for each part, its seconds and the RMS level of a 1 kHz tone in
    /// dBFS, or silence for nil.
    static func write(_ url: URL, _ parts: [(seconds: Double, dBFS: Double?)]) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let frames = Int(parts.reduce(0) { $0 + $1.seconds } * 48_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        var frame = 0
        for part in parts {
            let amplitude = part.dBFS.map { 2.0.squareRoot() * pow(10, $0 / 20) } ?? 0
            for _ in 0..<Int(part.seconds * 48_000) {
                buffer.floatChannelData![0][frame] = Float(amplitude * sin(2 * .pi * 1000 * Double(frame) / 48_000))
                frame += 1
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    /// The RMS level in dB of the export `wav` in the seconds of `window`.
    static func rms(_ wav: URL, _ window: Range<Double>) throws -> Double {
        let file = try AVAudioFile(forReading: wav)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        let range = Int(window.lowerBound * 48_000)..<Int(window.upperBound * 48_000)
        let square = range.reduce(0.0) { $0 + Double(samples[$1]) * Double(samples[$1]) } / Double(range.count)
        return 10 * log10(square)
    }

    /// C16: the music under speech is 16.0 dB under the music in the gap, 0.2 dB or less off. The
    /// gap window starts after the release and ends before the next attack.
    @Test func theMusicDropsSixteenDecibelsUnderSpeech() async throws {
        let duck = try await package.run("duck", "PKG")
        #expect(duck.status == 0, "\(duck)")
        #expect(duck.stdout == "speech\t96000\t288000\nspeech\t576000\t768000\nducked\tcm\n", "\(duck.stdout)")
        let wav = package.folder.appending(path: "music.wav")
        #expect(try await package.run("export", "PKG", "--out", wav.path, "--track", "m").status == 0)
        let (speech, gap) = (try Self.rms(wav, 3..<5), try Self.rms(wav, 8..<10))
        #expect(abs(speech - gap + 16) <= 0.2, "speech \(speech) dB, gap \(gap) dB")
    }

    /// No role and no list: exit 1 with the named text, and session.xml keeps its bytes.
    @Test func aSessionWithNoRoleAndNoListIsRefused() async throws {
        try package.edit { try $0.setRole(nil, tracks: ["v", "m"]) }
        let before = try package.xml()
        let duck = try await package.run("duck", "PKG")
        #expect(
            duck
                == CLIResult(
                    status: 1, stdout: "",
                    stderr: "Error: no speech track: give a track the dialogue role, or name the speech tracks.\n"))
        #expect(try package.xml() == before)
        let named = try await package.run("duck", "PKG", "--speech", "v", "--music", "m")
        #expect(named.status == 0, "the named lists duck: \(named)")
    }

    /// A track with no role is not ducked: an imported voice track `x` with no role keeps its clip.
    @Test func aTrackWithNoRoleIsNotDucked() async throws {
        try package.edit { session in
            try session.addTrack("x", name: "Import", layout: .mono)
            try session.place(Clip(id: "cx", file: "music", start: 0, offset: 0, length: 960_000), on: "x")
        }
        let duck = try await package.run("duck", "PKG")
        #expect(duck.status == 0, "\(duck)")
        let session = try package.read()
        #expect(session.clip("cx")?.clip.envelope == .empty && session.clip("cm")?.clip.envelope.isEmpty == false)
    }

    /// The music track soloed: the runs are the same, and the music ducks.
    @Test func aSoloedMusicTrackStillFindsTheRuns() async throws {
        try package.edit { try $0.setSoloed(true, tracks: ["m"]) }
        let duck = try await package.run("duck", "PKG")
        #expect(duck.stdout == "speech\t96000\t288000\nspeech\t576000\t768000\nducked\tcm\n", "\(duck)")
    }

    /// The speech track muted: the runs are the same, and the music ducks.
    @Test func aMutedSpeechTrackStillFindsTheRuns() async throws {
        try package.edit { try $0.setMuted(true, tracks: ["v"]) }
        let duck = try await package.run("duck", "PKG")
        #expect(duck.stdout == "speech\t96000\t288000\nspeech\t576000\t768000\nducked\tcm\n", "\(duck)")
    }

    /// Silent speech: exit 1 with the noSpeech text, and session.xml keeps its bytes.
    @Test func silentSpeechIsRefusedAndKeepsTheEnvelope() async throws {
        try Self.write(package.url.appending(path: "Clips/speech.wav"), [(20, -50)])
        let before = try package.xml()
        let duck = try await package.run("duck", "PKG")
        let text = "Error: no speech over -40.0 dBFS in the timeline frames 0..<960000, so the duck changed nothing.\n"
        #expect(duck == CLIResult(status: 1, stdout: "", stderr: text))
        #expect(try package.xml() == before)
    }

    /// Two music clips, speech over one: the other clip keeps its envelope, and the report names it.
    @Test func aMusicClipWithNoSpeechOverItKeepsItsEnvelope() async throws {
        try package.edit { session in
            try session.addFile(AudioFile(id: "intro", path: "music.wav", layout: .mono, length: 960_000))
            try session.place(Clip(id: "ci", file: "intro", start: 2_000_000, offset: 0, length: 480_000), on: "m")
            try session.setEnvelope([2_000_000: Gain(dB: -30)!, 2_048_000: .zero], clip: "ci")
        }
        let duck = try await package.run("duck", "PKG")
        #expect(duck.stdout.hasSuffix("ducked\tcm\nkept\tci\n"), "\(duck)")
        #expect(duck.stderr.contains("Clips that no speech reaches keep their envelope: 1."), "\(duck)")
        #expect(try package.read().clip("ci")?.clip.envelope.points.map(\.frame) == [0, 48_000])
    }

    /// A 30 s intro clip in a session of 10 minutes ducks, and its frames ascend strictly.
    @Test func aShortIntroClipInALongSessionDucks() async throws {
        try package.edit { session in
            try session.addFile(AudioFile(id: "long", path: "speech.wav", layout: .mono, length: 28_800_000))
            try session.place(Clip(id: "cl", file: "long", start: 960_000, offset: 0, length: 27_840_000), on: "v")
        }
        let duck = try await package.run("duck", "PKG")
        #expect(duck.status == 0, "\(duck)")
        let points = try #require(try package.read().clip("cm")?.clip.envelope.points)
        #expect(!points.isEmpty && zip(points, points.dropFirst()).allSatisfy { $0.frame < $1.frame })
    }

    /// A bad argument is a usage error: exit 64.
    @Test func aBadArgumentExits64() async throws {
        #expect(try await package.run("duck", "PKG", "--depth", "6").status == 64)
        #expect(try await package.run("duck", "PKG", "--from", "10").status == 64)
        #expect(try await package.run("duck", "PKG", "--attack", "-1").status == 64)
    }
}
