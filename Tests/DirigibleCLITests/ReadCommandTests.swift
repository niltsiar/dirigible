import DirigibleCore
import Foundation
import Testing

@testable import DirigibleMCP

/// `dirigible silences`, `dirigible nearest-pause`, and `dirigible meter` (decision 0062).
struct ReadCommandTests {
    let package: TemporaryPackage

    /// Track `t1` (stereo): the 1 s tone of `tone.wav` (-23 dBFS) as clip `c1` at frame 0 and as
    /// clip `c2` at frame 96,000. So frames 48,000 to 96,000 are silence, and the end is 144,000.
    /// Track `t2` (stereo): clip `g1` of `gone.wav`, which is not on the disk, over the silence;
    /// `t2` is muted.
    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "tone", path: "tone.wav", layout: .stereo, length: 48_000))
        try session.addFile(AudioFile(id: "gone", path: "gone.wav", layout: .stereo, length: 48_000))
        try session.addTrack("t1", name: "Host", layout: .stereo)
        try session.addTrack("t2", name: "Guest", layout: .stereo)
        try session.place(Clip(id: "c1", file: "tone", start: 0, offset: 0, length: 48_000), on: "t1")
        try session.place(Clip(id: "c2", file: "tone", start: 96_000, offset: 0, length: 48_000), on: "t1")
        try session.place(Clip(id: "g1", file: "gone", start: 48_000, offset: 0, length: 48_000), on: "t2")
        try session.setMuted(true, tracks: ["t2"])
        package = try TemporaryPackage(session)
        try LoudnessCommandTests.writeWAV(package.url.appending(path: "Clips/tone.wav"), seconds: 1)
    }

    static let refusal =
        "Error: file gone \"gone.wav\" is missing; its clips would read as silence, so the read gives no silence "
        + "or pause. Restore the file, or read a range or tracks without it.\n"

    /// With a held lock, each read gives its text from the files of track `t1` and writes nothing.
    @Test func eachReadPrintsItsTextAndTakesNoLock() async throws {
        let before = try package.xml()
        var results: [CLIResult] = []
        do {
            let lock = try PackageLock(package.url)
            defer { withExtendedLifetime(lock) {} }
            for read in [["silences"], ["nearest-pause", "--at", "50000"], ["meter"]] {
                results.append(try await package.run(read + ["PKG", "--track", "t1"]))
            }
        }
        #expect(results[0] == CLIResult(status: 0, stdout: "48000\t96000\n", stderr: ""))
        #expect(results[1] == CLIResult(status: 0, stdout: "pause\t48000\t96000\t72000\n", stderr: ""))
        let meter = results[2]
        #expect(meter.status == 0 && meter.stderr == "", "\(meter)")
        #expect(meter.stdout.hasPrefix("heard stereo mix: loudness -"), "\(meter.stdout)")
        #expect(meter.stdout.contains(", range none (under 2 min), max momentary -"), "\(meter.stdout)")
        #expect(meter.stdout.hasSuffix(" peak -23.0 dBFS\n"), "\(meter.stdout)")
        #expect(try package.xml() == before, "a read wrote session.xml")
    }

    @Test func aBadArgumentExits64AndAnUnknownTrackExits2() async throws {
        let level = try await package.run("silences", "PKG", "--threshold", "0")
        #expect(level.status == 64, "\(level)")
        #expect(level.stderr.contains("--threshold is a dB value under 0 and not under -96."), "\(level.stderr)")
        let step = try await package.run("meter", "PKG", "--step", "1000")
        #expect(step.status == 64, "\(step)")
        #expect(step.stderr.contains("--step must be a multiple of the 50 ms window, 2400 frames."), "\(step.stderr)")
        let track = try await package.run("silences", "PKG", "--track", "t9")
        #expect(track == CLIResult(status: 2, stdout: "", stderr: "Error: no track \"t9\".\n"))
    }

    /// The muted track `t2` counts for the pause reads, so its missing file refuses them. `meter`
    /// reads the heard mix: with `t2` muted it reads no fault; with `t2` heard, the warning comes
    /// first on stderr and the values on stdout, with exit 0.
    @Test func aMissingFileOnAMutedTrackRefusesTheSilences() async throws {
        for read in [["silences"], ["nearest-pause", "--at", "50000"]] {
            let result = try await package.run(read + ["PKG"])
            #expect(result == CLIResult(status: 2, stdout: "", stderr: Self.refusal), "\(read): \(result)")
        }
        let muted = try await package.run("meter", "PKG")
        #expect(muted.status == 0 && muted.stderr == "", "\(muted)")
        try package.edit { try $0.setMuted(false, tracks: ["t2"]) }
        let heard = try await package.run("meter", "PKG")
        #expect(heard.status == 0, "\(heard)")
        #expect(heard.stderr == "Warning: file gone \"gone.wav\" is missing; its clips render as silence.\n")
        #expect(heard.stdout.hasPrefix("heard stereo mix: "), "\(heard.stdout)")
    }

    /// The steps start on the frame 0 grid, and a step of digital silence gives none.
    @Test func aStepLineStartsOnTheGrid() async throws {
        let result = try await package.run("meter", "PKG", "--track", "t1", "--from", "1000", "--step", "48000")
        let lines = result.stdout.split(separator: "\n").map(String.init)
        #expect(result.status == 0 && lines.count == 4, "\(result)")
        #expect(lines.dropFirst().map { $0.prefix { $0 != "\t" } } == ["0", "48000", "96000"], "\(lines)")
        #expect(lines[1].hasSuffix("\t-23.0 dBFS") && lines[2] == "48000\tnone\tnone", "\(lines)")
    }
}
