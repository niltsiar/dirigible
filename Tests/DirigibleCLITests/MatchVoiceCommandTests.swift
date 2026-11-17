import AVFoundation
import DirigibleCore
import Foundation
import Testing

/// `dirigible track match-voice` (decision 0074, C15 and C20). Track `ref` holds clip `R` of the
/// file `r` (the reference), and tracks `t1` and `t2` hold clips `T1` and `T2` of the files `t1`
/// and `t2`. The reference is white noise and each target is the same kind of noise through a
/// low-pass, so a match has boosts and cuts.
struct MatchVoiceCommandTests {
    static let rate = 48_000

    /// Writes `Clips/<file>.wav` with `seconds` of noise from a fixed seed. With `dark`, a one-pole
    /// low-pass at about 1 kHz takes the highs out.
    static func write(_ file: String, seconds: Double, dark: Bool, in package: TemporaryPackage) throws {
        let frames = Int((seconds * Double(rate)).rounded())
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        var (state, low) = (UInt64(7), 0.0)
        for frame in 0..<frames {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Double(state >> 11) / Double(1 << 53) * 2 - 1
            low += (noise - low) * 0.12
            buffer.floatChannelData![0][frame] = Float(dark ? low * 1.5 : noise * 0.3)
        }
        let output = try AVAudioFile(
            forWriting: package.url.appending(path: "Clips/\(file).wav"), settings: format.settings)
        try output.write(from: buffer)
    }

    /// The package: a reference of `reference` seconds, and a target of `targets[i]` seconds on
    /// track `t<i+1>`.
    static func package(reference: Double = 12, targets: [Double] = [12, 12]) throws -> TemporaryPackage {
        var session = Session(sampleRate: rate)
        let all =
            [("r", "ref", "R", reference)] + targets.enumerated().map { ("t\($0 + 1)", "t\($0 + 1)", "T\($0 + 1)", $1) }
        for (file, track, clip, seconds) in all {
            let length = Frames(Int((seconds * Double(rate)).rounded()))
            try session.addFile(AudioFile(id: FileID(file), path: "\(file).wav", layout: .mono, length: length))
            try session.addTrack(TrackID(track), name: track, layout: .mono)
            try session.place(
                Clip(id: ClipID(clip), file: FileID(file), start: 0, offset: 0, length: length), on: TrackID(track))
        }
        let package = try TemporaryPackage(session)
        try FileManager.default.createDirectory(
            at: package.url.appending(path: "Clips"), withIntermediateDirectories: true)
        for (file, _, _, seconds) in all { try write(file, seconds: seconds, dark: file != "r", in: package) }
        return package
    }

    /// The text of a boost or a cut in dB: `+4.2 dB`, `-3.1 dB`, and `0.0 dB` for none.
    static func decibels(_ value: Double) -> String { value == 0 ? "0.0 dB" : String(format: "%+.1f dB", value) }

    /// The line of a track with a match, from the stored value.
    static func line(_ track: String, in session: Session) throws -> String {
        let match = try #require(session.track(TrackID(track))?.match)
        let (boost, cut) = match.extremes(at: match.amount)
        return
            "\(track): match \(match.amount.percent) % (\(decibels(boost)), \(decibels(cut)))"
            + (match.isBypassed ? ", bypassed" : "")
    }

    /// One line for each track, with the stored amount and the largest boost and cut. The match has
    /// the name of the reference file, the default amount, and no bypass. No audio file changes.
    @Test func matchesAndPrints() async throws {
        let package = try Self.package()
        let before = DenoiseCommandTests.clips(package)

        let result = try await package.run("track", "match-voice", "PKG", "--reference", "R", "t1", "t2")

        let session = try package.read()
        let lines = try ["t1", "t2"].map { try Self.line($0, in: session) }
        #expect(
            result == CLIResult(status: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: ""),
            "match-voice: \(result)")
        let match = try #require(session.track("t1")?.match)
        #expect(match.reference == "r" && match.amount == VoiceMatch.defaultAmount && !match.isBypassed)
        #expect(match.curve.decibels.contains { abs($0) > 1 }, "the curve is flat: \(match.curve.decibels)")
        #expect(session.track("ref")?.match == nil, "the reference track has no match")
        #expect(DenoiseCommandTests.clips(package) == before, "a match writes no audio file")
    }

    /// A replace keeps the amount of the track unless `--amount` gives one, and turns the bypass
    /// off. A new match takes 75.
    @Test func replaceKeepsTheAmount() async throws {
        let package = try Self.package()
        _ = try await package.run("track", "match-voice", "PKG", "--reference", "R", "t1")
        let kept = try await package.run("track", "match-voice", "PKG", "--amount", "40", "--bypass", "on", "t1")
        try #require(kept.status == 0, "\(kept)")

        let both = try await package.run("track", "match-voice", "PKG", "--reference", "R", "t1", "t2")

        var session = try package.read()
        #expect(both.status == 0, "\(both)")
        #expect(session.track("t1")?.match?.amount.percent == 40 && session.track("t1")?.match?.isBypassed == false)
        #expect(session.track("t2")?.match?.amount == VoiceMatch.defaultAmount)

        let given = try await package.run(
            "track", "match-voice", "PKG", "--reference", "R", "--amount", "60", "t1", "t2")

        session = try package.read()
        #expect(given.status == 0, "\(given)")
        #expect(session.track("t1")?.match?.amount.percent == 60 && session.track("t2")?.match?.amount.percent == 60)
    }

    /// The amount, the bypass, both in one edit, and the remove each print one line for each track
    /// and read no audio.
    @Test func editsPrint() async throws {
        let package = try Self.package()
        try package.edit { session in
            for track: TrackID in ["t1", "t2"] {
                let match = try VoiceMatch(
                    amount: VoiceMatch.defaultAmount, reference: "r", curve: (0..<25).map { Double($0 % 5) - 2 },
                    targetPowers: [Double](repeating: 1, count: 25))
                try session.setMatch([track: match])
            }
        }
        try FileManager.default.removeItem(at: package.url.appending(path: "Clips"))

        let amount = try await package.run("track", "match-voice", "PKG", "--amount", "50", "t1", "t2")
        var session = try package.read()
        #expect(
            amount
                == CLIResult(
                    status: 0, stdout: try ["t1", "t2"].map { try Self.line($0, in: session) + "\n" }.joined(),
                    stderr: ""),
            "\(amount)")
        #expect(session.track("t1")?.match?.amount.percent == 50)

        let bypass = try await package.run("track", "match-voice", "PKG", "--bypass", "on", "t1")
        session = try package.read()
        #expect(
            bypass == CLIResult(status: 0, stdout: try Self.line("t1", in: session) + "\n", stderr: ""), "\(bypass)")
        #expect(bypass.stdout.hasSuffix(", bypassed\n") && session.track("t2")?.match?.isBypassed == false)

        let both = try await package.run("track", "match-voice", "PKG", "--amount", "20", "--bypass", "off", "t1")
        session = try package.read()
        #expect(both == CLIResult(status: 0, stdout: try Self.line("t1", in: session) + "\n", stderr: ""), "\(both)")
        #expect(session.track("t1")?.match?.amount.percent == 20 && session.track("t1")?.match?.isBypassed == false)

        let removed = try await package.run("track", "match-voice", "PKG", "--remove", "t1", "ref")
        #expect(removed == CLIResult(status: 0, stdout: "t1: match removed\nref: no match\n", stderr: ""), "\(removed)")
        session = try package.read()
        #expect(session.track("t1")?.match == nil && session.track("t2")?.match != nil)
    }

    /// 1 and 100 pass; 0, 101, and `nan` exit 64 and change nothing.
    @Test(arguments: [("1", 0), ("100", 0), ("0", 64), ("101", 64), ("nan", 64), ("50.5", 64)])
    func amountRange(amount: String, status: Int32) async throws {
        let package = try Self.package()
        try package.edit { session in
            try session.setMatch([
                "t1": try VoiceMatch(
                    amount: VoiceMatch.defaultAmount, reference: "r", curve: [Double](repeating: 1, count: 25),
                    targetPowers: [Double](repeating: 1, count: 25))
            ])
        }
        let before = try package.xml()

        let result = try await package.run("track", "match-voice", "PKG", "--amount", amount, "t1")

        #expect(result.status == status, "\(amount): \(result)")
        let unchanged = try package.xml() == before
        #expect(status == 0 || unchanged, "\(amount) changed the package")
    }

    /// `on` and `off` pass; `yes` exits 64.
    @Test(arguments: [("on", 0), ("off", 0), ("yes", 64), ("true", 64), ("ON", 64)])
    func bypassWord(word: String, status: Int32) async throws {
        let package = try Self.package()
        try package.edit { session in
            try session.setMatch([
                "t1": try VoiceMatch(
                    amount: VoiceMatch.defaultAmount, reference: "r", curve: [Double](repeating: 1, count: 25),
                    targetPowers: [Double](repeating: 1, count: 25))
            ])
        }

        let result = try await package.run("track", "match-voice", "PKG", "--bypass", word, "t1")

        #expect(result.status == status, "\(word): \(result)")
    }

    /// Each argument that does not fit its mode exits 64 with a text on stderr and reads no audio.
    @Test(arguments: [
        ["--from", "0", "--reference", "R", "t1"], ["--to", "10", "--reference", "R", "t1"],
        ["--from", "0", "--to", "10", "t1"], ["--from", "1", "--to", "1", "--reference", "R", "t1"],
        ["--from", "5", "--to", "1", "--reference", "R", "t1"], ["--remove", "--reference", "R", "t1"],
        ["--remove", "--amount", "50", "t1"], ["--remove", "--bypass", "on", "t1"],
        ["--reference", "R", "--bypass", "on", "t1"], ["--reference", "R"], ["--amount", "50"], ["t1"],
    ])
    func badArgumentsExit64(arguments: [String]) async throws {
        let package = try Self.package()
        let before = try package.xml()

        let result = try await package.run(["track", "match-voice", "PKG"] + arguments)

        #expect(result.status == 64 && result.stdout == "", "\(arguments): \(result)")
        #expect(result.stderr.contains("Error: "), "\(result.stderr)")
        #expect(try package.xml() == before)
    }

    /// A range that ends at the clip end passes. A range one frame past it exits 1, prints the clip
    /// span, and changes nothing. `--from 0 --to 1` passes the argument check and then has no voice.
    @Test func rangeInsideTheClip() async throws {
        let package = try Self.package()
        let end = 12 * Self.rate

        let inside = try await package.run(
            "track", "match-voice", "PKG", "--reference", "R", "--from", "0", "--to", "\(end)", "t1")
        #expect(inside.status == 0, "\(inside)")

        let before = try package.xml()
        let past = try await package.run(
            "track", "match-voice", "PKG", "--reference", "R", "--from", "0", "--to", "\(end + 1)", "t2")
        #expect(
            past
                == CLIResult(
                    status: 1, stdout: "",
                    stderr: "Error: the range must lie inside the reference clip, frames 0 to \(end).\n"
                ), "\(past)")
        #expect(try package.xml() == before)

        let tiny = try await package.run(
            "track", "match-voice", "PKG", "--reference", "R", "--from", "0", "--to", "1", "t2")
        #expect(
            tiny.status == 1 && tiny.stderr == "Error: the reference clip has 0 s of voice; Match Voice needs 10 s.\n",
            "\(tiny)")
    }

    /// The range is part of the voice that counts: 12 s of reference with a range of 9.9 s refuses
    /// with 9 s; a range of 10.0 s passes.
    @Test(arguments: [(475_200, 1), (480_000, 0)])
    func rangeCountsItsVoice(frames: Int, status: Int32) async throws {
        let package = try Self.package()

        let result = try await package.run(
            "track", "match-voice", "PKG", "--reference", "R", "--from", "0", "--to", "\(frames)", "t1")

        #expect(result.status == status, "\(frames): \(result)")
        #expect(
            status == 0 || result.stderr == "Error: the reference clip has 9 s of voice; Match Voice needs 10 s.\n",
            "\(result.stderr)")
    }

    /// 9.9 s of voice on a side exits 1 and names the side with 9 s, and changes nothing; 10.0 s
    /// passes. The reference is read before the targets.
    @Test(arguments: [(9.9, true), (10.0, true), (9.9, false), (10.0, false)])
    func tooLittleVoice(seconds: Double, onReference: Bool) async throws {
        let package = try Self.package(reference: onReference ? seconds : 12, targets: [onReference ? 12 : seconds])
        let before = try package.xml()

        let result = try await package.run("track", "match-voice", "PKG", "--reference", "R", "t1")

        if seconds < 10 {
            let side = onReference ? "the reference clip" : "track t1"
            #expect(
                result
                    == CLIResult(
                        status: 1, stdout: "", stderr: "Error: \(side) has 9 s of voice; Match Voice needs 10 s.\n"),
                "\(result)")
            #expect(try package.xml() == before)
        } else {
            #expect(result.status == 0, "\(result)")
        }
    }

    /// An unknown clip or track exits 1 with its ID. The near input, a clip that exists on a track
    /// that exists, passes.
    @Test func unknownClipAndTrackExit1() async throws {
        let package = try Self.package()
        let before = try package.xml()

        let clip = try await package.run("track", "match-voice", "PKG", "--reference", "zz", "t1")
        let track = try await package.run("track", "match-voice", "PKG", "--reference", "R", "t1", "zz")
        let amount = try await package.run("track", "match-voice", "PKG", "--amount", "50", "zz")

        for result in [clip, track, amount] {
            #expect(result.status == 1 && result.stdout == "" && result.stderr.contains("zz"), "\(result)")
        }
        #expect(try package.xml() == before)
    }

    /// `--amount` or `--bypass` on a track with no match exits 1 with the session text, and a
    /// remove of that track is not an error.
    @Test func noMatchExit1() async throws {
        let package = try Self.package()
        let before = try package.xml()

        for option in [["--amount", "50"], ["--bypass", "on"]] {
            let result = try await package.run(["track", "match-voice", "PKG"] + option + ["t1"])
            #expect(
                result == CLIResult(status: 1, stdout: "", stderr: "Error: track \"t1\" has no voice match.\n"),
                "\(option): \(result)")
        }
        #expect(try package.xml() == before)
    }

    /// A music track is left out with its own line; the other tracks match. With no track left,
    /// the command exits 1.
    @Test func musicTrackIsLeftOut() async throws {
        let package = try Self.package()
        try package.edit { try $0.setRole(.music, tracks: ["t2"]) }

        let result = try await package.run("track", "match-voice", "PKG", "--reference", "R", "t1", "t2")

        let session = try package.read()
        let text = try Self.line("t1", in: session) + "\nt2: left out, a music or effects track\n"
        #expect(result == CLIResult(status: 0, stdout: text, stderr: ""), "\(result)")
        #expect(session.track("t2")?.match == nil)

        let none = try await package.run("track", "match-voice", "PKG", "--reference", "R", "t2")
        #expect(
            none
                == CLIResult(
                    status: 1, stdout: "",
                    stderr: "Error: Match Voice leaves out music and effects tracks, so no track is left to match.\n"),
            "\(none)")
    }

    /// A source that is missing exits 1 with the file and "no track changed", and changes nothing.
    @Test func unreadableSourceExits1() async throws {
        let package = try Self.package()
        try FileManager.default.removeItem(at: package.url.appending(path: "Clips/t1.wav"))
        let before = try package.xml()

        let result = try await package.run("track", "match-voice", "PKG", "--reference", "R", "t1")

        #expect(
            result == CLIResult(status: 1, stdout: "", stderr: "Error: file t1 is missing; no track changed.\n"),
            "\(result)")
        #expect(try package.xml() == before)
    }

    /// A take that is not finalized refuses the command with exit 2 and the take text.
    @Test func pendingTakeExits2() async throws {
        let package = try Self.package()
        try package.edit {
            try $0.setRecording(Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 0, armedTracks: ["t1"]))
        }
        let before = try package.xml()

        let result = try await package.run("track", "match-voice", "PKG", "--reference", "R", "t1")

        #expect(result.status == 2 && result.stdout == "" && result.stderr.hasPrefix("Error: "), "\(result)")
        #expect(try package.xml() == before)
    }

    /// Control-C after the read leaves `session.xml` as it was and exits 130 with nothing on
    /// stdout. The child holds after the read and says so on stderr (`DIRIGIBLE_MATCH_HOLD`), so the
    /// signal comes before the save at any load.
    @Test func interruptWritesNothing() async throws {
        let package = try Self.package()
        let before = (try package.xml(), DenoiseCommandTests.clips(package))
        let (stdout, stderr) = (package.folder.appending(path: "stdout"), package.folder.appending(path: "stderr"))
        let pid = try spawnDirigible(
            "track", "match-voice", package.path, "--reference", "R", "t1", environment: ["DIRIGIBLE_MATCH_HOLD": "1"],
            output: (stdout, stderr))
        var status: Int32 = 0
        defer {
            if waitpid(pid, &status, WNOHANG) == 0 {
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
            }
        }
        let end = ContinuousClock.now + .seconds(60)
        while (try? String(contentsOf: stderr, encoding: .utf8)) != "hold\n", ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(try String(contentsOf: stderr, encoding: .utf8) == "hold\n", "the command did not hold in 60 s")

        kill(pid, SIGINT)
        let stop = ContinuousClock.now + .seconds(60)
        var finished = waitpid(pid, &status, WNOHANG)
        while finished == 0, ContinuousClock.now < stop {
            try await Task.sleep(for: .milliseconds(1))
            finished = waitpid(pid, &status, WNOHANG)
        }

        try #require(finished == pid, "the command did not end in 60 s")
        #expect(status >> 8 == 128 + SIGINT && status & 0x7f == 0, "wait status \(status)")
        #expect(try String(contentsOf: stdout, encoding: .utf8) == "", "an interrupted match printed")
        #expect(try package.xml() == before.0, "an interrupted match changed session.xml")
        #expect(DenoiseCommandTests.clips(package) == before.1)
    }
}
