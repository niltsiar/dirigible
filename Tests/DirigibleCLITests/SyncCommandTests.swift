import AVFoundation
import DirigibleAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleCLI
@testable import DirigibleMCP

/// `dirigible clip sync` (decision 0076, C11). Track `guest` holds clip `C` (file `c`, 90 s of noise)
/// at 30 s, and track `ref` holds clip `R` (file `r`, 150 s). The reference variants hold the audio
/// of `C` at 10 s with background noise, so the lag is -20 s (-960000 frames).
struct SyncCommandTests {
    static let rate = 48_000
    static let (clipSeconds, referenceSeconds) = (90, 150)

    /// Seeded noise of `seconds`, uniform in -`amplitude`...`amplitude`.
    static func noise(seed: UInt64, seconds: Int, amplitude: Float) -> [Float] {
        var (state, samples) = (seed, [Float]())
        samples.reserveCapacity(seconds * rate)
        for _ in 0..<seconds * rate {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 11) / Double(1 << 53) * 2 - 1
            samples.append(Float(unit) * amplitude)
        }
        return samples
    }

    static func write(_ samples: [Float], to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    /// The reference files, written once: `r-full` holds all of `C` at 10 s at half gain, `r-first` holds
    /// its first 30 s (so 1 of the 3 excerpts matches), and `r-other` is noise with nothing of `C`.
    private static let audio: Result<URL, any Error> = Result {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SyncCommandTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clip = noise(seed: 1, seconds: clipSeconds, amplitude: 0.3)
        try write(clip, to: folder.appending(path: "c.wav"))
        for (name, copied) in [("r-full", clip.count), ("r-first", 30 * rate)] {
            var reference = noise(seed: 2, seconds: referenceSeconds, amplitude: 0.1)
            for index in 0..<copied { reference[10 * rate + index] += 0.5 * clip[index] }
            try write(reference, to: folder.appending(path: "\(name).wav"))
        }
        try write(noise(seed: 3, seconds: referenceSeconds, amplitude: 0.3), to: folder.appending(path: "r-other.wav"))
        return folder
    }

    /// The package of the header. With a `reference`, the WAV files are in `Clips/`; with nil, no file exists.
    static func package(reference: String? = nil) throws -> TemporaryPackage {
        let length = { (seconds: Int) in Frames(seconds * rate) }
        var session = Session(sampleRate: rate)
        for (file, track, id, start, frames) in [
            ("r", "ref", "R", 0, length(referenceSeconds)), ("c", "guest", "C", 30, length(clipSeconds)),
        ] {
            try session.addFile(AudioFile(id: FileID(file), path: "\(file).wav", layout: .mono, length: frames))
            try session.addTrack(TrackID(track), name: track, layout: .mono)
            try session.place(
                Clip(id: ClipID(id), file: FileID(file), start: length(start), offset: 0, length: frames),
                on: TrackID(track))
        }
        let package = try TemporaryPackage(session)
        guard let reference else { return package }
        let clips = package.url.appending(path: "Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let folder = try audio.get()
        try FileManager.default.copyItem(at: folder.appending(path: "c.wav"), to: clips.appending(path: "c.wav"))
        try FileManager.default.copyItem(
            at: folder.appending(path: "\(reference).wav"), to: clips.appending(path: "r.wav"))
        return package
    }

    /// A match moves the clip by the lag with the sign and the frames, and saves. A copy that
    /// matches in each third has no spread line.
    @Test func aMatchPrintsTheMoveAndSaves() async throws {
        let package = try Self.package(reference: "r-full")

        let result = try await package.run("clip", "sync", "PKG", "C", "--to", "ref")

        let line = /moved C by -20\.000 s \(-960000 frames\), match (\d\.\d\d)\n/
        let match = try #require(result.stdout.wholeMatch(of: line), "stdout: \(result.stdout)")
        #expect(result.status == 0 && result.stderr == "", "\(result)")
        #expect((Double(match.1) ?? 0) >= 0.5, "match \(match.1)")
        #expect(try package.read().clip("C")?.clip.start == 480_000)
    }

    /// Only the first third of the clip is on the reference, so the spread is not known: the line
    /// says so, and the JSON has `null`.
    @Test func oneMatchedPartPrintsThatTheDriftWasNotMeasured() async throws {
        let package = try Self.package(reference: "r-first")

        let result = try await package.run("clip", "sync", "PKG", "C", "--to", "ref")

        let text = /moved C by -20\.000 s \(-960000 frames\), match \d\.\d\d\n/
        let unmeasured = "the drift was not measured: only one part of the clip matched\n"
        #expect(result.status == 0 && result.stdout.hasSuffix(unmeasured), "\(result)")
        #expect(result.stdout.dropLast(unmeasured.count).wholeMatch(of: text) != nil, "stdout: \(result.stdout)")
    }

    @Test func jsonHasEachKey() async throws {
        let package = try Self.package(reference: "r-first")

        let result = try await package.run("clip", "sync", "PKG", "C", "--to", "ref", "--json")

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any], "\(result)")
        #expect(result.status == 0 && result.stdout.hasSuffix("}\n") && result.stdout.filter { $0 == "\n" }.count == 1)
        #expect(Set(object.keys) == ["clip", "frames", "seconds", "match", "spread", "headCut"], "\(object)")
        #expect(object["clip"] as? String == "C" && object["frames"] as? Int == -960_000)
        #expect(object["seconds"] as? Double == -20 && object["headCut"] as? Int == 0)
        #expect(object["spread"] is NSNull, "spread: \(String(describing: object["spread"]))")
        #expect((object["match"] as? Double ?? 0) >= 0.5)
    }

    /// No match exits 1, says so, and writes nothing.
    @Test func noMatchExits1AndChangesNothing() async throws {
        let package = try Self.package(reference: "r-other")
        let before = try package.xml()

        let result = try await package.run("clip", "sync", "PKG", "C", "--to", "ref")

        #expect(
            result
                == CLIResult(
                    status: 1, stdout: "", stderr: "Error: No match: the clip audio was not found on the track.\n"))
        #expect(try package.xml() == before)
    }

    /// A `within` of 0 or under, or that is not a number, exits 64 before any read.
    @Test(arguments: ["0", "-5", "1.5", "many"])
    func aBadWithinExits64(within: String) async throws {
        let package = try Self.package()
        let before = try package.xml()

        let result = try await package.run("clip", "sync", "PKG", "C", "--to", "ref", "--within", within)

        #expect(result.status == 64 && result.stdout == "" && result.stderr.contains("within"), "\(result)")
        #expect(try package.xml() == before)
    }

    /// The text of a `within` over the cap names the cap of the rate of the session and the largest
    /// `within` of the clip. A 1 h clip at 44.1 kHz, with 2400 s on each side: the cap is 8309 s and
    /// the largest `within` is 2354 s, so 2355 exits 64 and 2354 goes on to the read.
    @Test func aWithinOverTheCapNamesTheCapOfTheRate() async throws {
        var session = Session(sampleRate: 44_100)
        for (file, track, id, start, seconds) in [("r", "ref", "R", 0, 8400), ("c", "guest", "C", 2400, 3600)] {
            let length = Frames(seconds * 44_100)
            try session.addFile(AudioFile(id: FileID(file), path: "\(file).wav", layout: .mono, length: length))
            try session.addTrack(TrackID(track), name: track, layout: .mono)
            try session.place(
                Clip(id: ClipID(id), file: FileID(file), start: Frames(start * 44_100), offset: 0, length: length),
                on: TrackID(track))
        }
        let package = try TemporaryPackage(session)
        let before = try package.xml()

        let over = try await package.run("clip", "sync", "PKG", "C", "--to", "ref", "--within", "2355")
        let largest = try await package.run("clip", "sync", "PKG", "C", "--to", "ref", "--within", "2354")

        #expect(
            over
                == CLIResult(
                    status: 64, stdout: "",
                    stderr: "Error: The search span is over 8309 s. Use --within 2354 or less for this clip.\n"))
        #expect(largest.status == 2, "the largest within reads the files: \(largest)")
        #expect(try package.xml() == before)
    }

    /// A clip that alone is over the cap has no `within` that fits, so it exits 64.
    @Test func aClipOverTheCapExits64() async throws {
        var session = Session(sampleRate: 44_100)
        let length = Frames(8310 * 44_100)
        for (file, track, id) in [("r", "ref", "R"), ("c", "guest", "C")] {
            try session.addFile(AudioFile(id: FileID(file), path: "\(file).wav", layout: .mono, length: length))
            try session.addTrack(TrackID(track), name: track, layout: .mono)
            try session.place(
                Clip(id: ClipID(id), file: FileID(file), start: 0, offset: 0, length: length), on: TrackID(track))
        }
        let package = try TemporaryPackage(session)

        let result = try await package.run("clip", "sync", "PKG", "C", "--to", "ref")

        #expect(
            result
                == CLIResult(
                    status: 64, stdout: "",
                    stderr: "Error: the clip is longer than the longest span that a sync reads.\n"))
    }

    /// A clip file or a reference file that is missing exits 2 with the file and the fault, and
    /// changes nothing.
    @Test(arguments: ["c", "r"])
    func aMissingFileExits2(file: String) async throws {
        let package = try Self.package(reference: "r-full")
        try FileManager.default.removeItem(at: package.url.appending(path: "Clips/\(file).wav"))
        let before = try package.xml()

        let result = try await package.run("clip", "sync", "PKG", "C", "--to", "ref")

        #expect(
            result
                == CLIResult(status: 2, stdout: "", stderr: "Error: file \(file) is missing; no clip moved.\n"),
            "\(result)")
        #expect(try package.xml() == before)
    }

    /// A refusal of the session exits 1 with its text: the reference is the track of the clip.
    @Test func aRefusalOfTheSessionExits1() async throws {
        let package = try Self.package()

        let result = try await package.run("clip", "sync", "PKG", "C", "--to", "guest")

        #expect(
            result
                == CLIResult(
                    status: 1, stdout: "",
                    stderr: "Error: the reference is the track of the clip; name another track.\n"))
    }

    /// Each failure of the work has its exit code and its text: a bad argument 64, no match and a
    /// refusal of the session 1, a file fault and a read errno 2, and a cancel 130.
    @Test func eachFailureHasItsExitCode() throws {
        let command = try ClipCommand.Sync.parse(["/x.dirigible", "C", "--to", "ref"])
        let none = MatchScore(peak: 0, ratio: 0)
        let rows: [(SyncRefusal, Int32, String)] = [
            (.argument("a bad argument."), 64, "a bad argument."),
            (.studio(.syncNoMatch(best: none)), 1, "No match: the clip audio was not found on the track."),
            (.studio(.session(.noReferenceAudio)), 1, SessionError.noReferenceAudio.message),
            (.studio(.syncFile("c", .unreadable)), 2, "file c cannot be read; no clip moved."),
            (.studio(.syncRead(EMFILE)), 2, audioReadMessage(POSIXError(.EMFILE))),
            (.studio(.syncCancelled), 130, "the sync was cancelled."),
        ]
        for (refusal, code, text) in rows {
            #expect(command.failure(refusal).rawValue == code, "\(refusal)")
            #expect(refusal.message(package: "/x.dirigible") == text, "\(refusal)")
        }
    }
}
