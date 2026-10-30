import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// `dirigible clip repair` (decision 0064, criteria C12 and C19). Most tests use the package of
/// `DenoiseCommandTests`.
struct RepairCommandTests {
    /// A package at `rate` with the clip `c1` of 1 s of a tone, made by `dirigible import` of a 48 kHz
    /// WAV, so the file is a file that the product makes at that rate.
    static func package(rate: Int) async throws -> TemporaryPackage {
        let package = try TemporaryPackage(Session(sampleRate: rate))
        let tone = package.folder.appending(path: "tone.wav")
        try LoudnessCommandTests.writeWAV(tone, seconds: 1, channels: 1)
        let made = try await package.run("import", "PKG", tone.path, "--at", "0", "--id", "c1", "--no-level")
        try #require(made.status == 0, "\(made)")
        return package
    }

    /// The effects of the origin levels of `c1`, bottom to top.
    static func effects(of package: TemporaryPackage) throws -> [Effect] {
        try package.read().origins(of: "c1").flatMap(\.treatment.effects)
    }

    /// C12: each option writes its element with its value, a bare option writes its standard value,
    /// and the line is the clip and its new file. The values are literal: 80 Hz, 99 percent, 6,000 Hz
    /// and 10 dB are the standard values.
    @Test(arguments: [
        (["--rumble", "120"], [Effect.rumble(Rumble(hertz: 120)!)]),
        (["--rumble"], [.rumble(Rumble(hertz: 80)!)]),
        (["--clipping", "95"], [.declip(Declip(percent: 95)!)]),
        (["--clipping"], [.declip(Declip(percent: 99)!)]),
        (["--sibilance", "8"], [.deess(DeEss(hertz: 6_000, decibels: 8)!)]),
        (["--sibilance", "--sibilance-hz", "5000"], [.deess(DeEss(hertz: 5_000, decibels: 10)!)]),
        (
            ["--sibilance", "--rumble", "--clipping"],
            [
                .declip(Declip(percent: 99)!), .rumble(Rumble(hertz: 80)!),
                .deess(DeEss(hertz: 6_000, decibels: 10)!),
            ]
        ),
    ])
    func eachOptionWritesItsElement(options: [String], effects: [Effect]) async throws {
        let package = try DenoiseCommandTests.package()

        let result = try await package.run(["clip", "repair", "PKG", "c1"] + options)

        let file = try DenoiseCommandTests.played("c1", in: package)
        let repair = effects.contains { $0.kind == .declip } ? "c1: 0 clipped runs repaired, level drop 0.0 dB\n" : ""
        #expect(
            result == CLIResult(status: 0, stdout: "c1\t\(file.id)\n" + repair, stderr: ""), "\(options): \(result)")
        #expect(try Self.effects(of: package) == effects, "\(options)")
        #expect(DenoiseCommandTests.clips(package).contains(file.path), "\(DenoiseCommandTests.clips(package))")
    }

    /// `DenoiseCommandTests.package()` with the file `f1` rewritten as 4 s of a 440 Hz sine of 1.4
    /// clipped at 0.99, so the de-clip finds runs in `c1`.
    static func clippedPackage() throws -> TemporaryPackage {
        let package = try DenoiseCommandTests.package()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(forWriting: package.url.appending(path: "Clips/f1.wav"), settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000))
        buffer.frameLength = 192_000
        for frame in 0..<192_000 {
            buffer.floatChannelData![0][frame] = Float(
                max(-0.99, min(0.99, 1.4 * sin(2 * .pi * 440 * Double(frame) / 48_000))))
        }
        try file.write(from: buffer)
        return package
    }

    /// Decision 0011 (CLI parity): a clip with a de-clip gets a line with its clipped runs and its
    /// level drop in dB, the values of the render that the app banner names. The runs and the drop
    /// are those of `renderRequest` on the same package. Fail: no line (the output of gate 1, which
    /// told the user to use clip gain with no number).
    @Test func clippingPrintsTheRunsAndTheLevelDrop() async throws {
        let (command, direct) = (try Self.clippedPackage(), try Self.clippedPackage())

        let result = try await command.run("clip", "repair", "PKG", "c1", "--clipping")

        let outcome = try renderRequest(
            ["c1"], request: ClipRenderRequest(Treatment(.declip(.standard))), of: try direct.read(), in: direct.url,
            freeBytes: { .max }, isDownloaded: { _ in true })
        let repair = try #require(outcome.repairs["c1"])
        let file = try DenoiseCommandTests.played("c1", in: command)
        let text = "c1: \(repair.runs) clipped runs repaired, level drop \(String(format: "%.1f", repair.levelDrop)) dB"
        #expect(repair.runs > 1 && repair.levelDrop > 0.1, "\(repair)")
        #expect(result == CLIResult(status: 0, stdout: "c1\t\(file.id)\n\(text)\n", stderr: ""), "\(result)")
    }

    /// C12: no effect exits 64 and changes nothing. The sibilance frequency alone is no effect.
    @Test(arguments: [
        ([String](), "Give at least one repair: rumble, clipping, or sibilance."),
        (["--sibilance-hz", "5000"], "A sibilance frequency needs a sibilance."),
    ])
    func noEffectExits64(options: [String], reason: String) async throws {
        let package = try DenoiseCommandTests.package()
        let before = (try package.xml(), DenoiseCommandTests.clips(package))

        let result = try await package.run(["clip", "repair", "PKG", "c1"] + options)

        #expect(result.status == 64 && result.stdout == "", "\(options): \(result)")
        #expect(result.stderr.contains(reason), "\(options): \(result.stderr)")
        let after = (try package.xml(), DenoiseCommandTests.clips(package))
        #expect(after == before, "a refused call changed the package")
    }

    /// C12: a value past its end, or one that is not a whole number, exits 64, names the range in
    /// the text, and changes nothing (fail: exit 0).
    @Test(arguments: [
        (["--rumble", "301"], "A rumble is an integer from 20 to 300."),
        (["--rumble", "19"], "A rumble is an integer from 20 to 300."),
        (["--rumble", "abc"], "A rumble is an integer from 20 to 300."),
        (["--clipping", "89"], "A clipping is an integer from 90 to 100."),
        (["--clipping", "101"], "A clipping is an integer from 90 to 100."),
        (["--sibilance", "0"], "A sibilance is an integer from 1 to 40."),
        (["--sibilance", "41"], "A sibilance is an integer from 1 to 40."),
        (["--sibilance", "--sibilance-hz", "1999"], "A sibilance frequency is an integer from 2000 to 16000."),
        (["--sibilance", "--sibilance-hz", "16001"], "A sibilance frequency is an integer from 2000 to 16000."),
    ])
    func valuePastItsEndExits64(options: [String], reason: String) async throws {
        let package = try DenoiseCommandTests.package()
        let before = (try package.xml(), DenoiseCommandTests.clips(package))

        let result = try await package.run(["clip", "repair", "PKG", "c1"] + options)

        #expect(result.status == 64 && result.stdout == "", "\(options): \(result)")
        #expect(result.stderr.contains(reason), "\(options): \(result.stderr)")
        let after = (try package.xml(), DenoiseCommandTests.clips(package))
        #expect(after == before, "a refused call changed the package")
    }

    /// C19: on a 22,050 Hz package a corner of 9,922 Hz renders and 9,923 Hz is refused with the
    /// limit in the text; the refusal changes no byte of `session.xml` and no file in `Clips/`
    /// (fail: a render that clamps the corner).
    @Test func cornerOverTheSessionLimitIsRefused() async throws {
        let (accepted, refused) = (try await Self.package(rate: 22_050), try await Self.package(rate: 22_050))
        let before = (try refused.xml(), DenoiseCommandTests.clips(refused))

        let ok = try await accepted.run("clip", "repair", "PKG", "c1", "--sibilance", "--sibilance-hz", "9922")
        let result = try await refused.run("clip", "repair", "PKG", "c1", "--sibilance", "--sibilance-hz", "9923")

        let file = try DenoiseCommandTests.played("c1", in: accepted)
        #expect(ok == CLIResult(status: 0, stdout: "c1\t\(file.id)\n", stderr: ""), "9922 Hz: \(ok)")
        #expect(result.status == 1 && result.stdout == "", "9923 Hz: \(result)")
        #expect(result.stderr.contains("9923 Hz") && result.stderr.contains("9922 Hz"), "\(result.stderr)")
        let after = (try refused.xml(), DenoiseCommandTests.clips(refused))
        #expect(after == before, "a refused call changed the package")
    }

    /// C19: the lowest session rate that takes a de-ess is 4,445 Hz. At that rate 2,000 Hz renders. At
    /// 4,444 Hz it is refused, and the text names the rate, not a corner that the type refuses
    /// (fail: the limit text of gate 1, which names 1,999 Hz).
    @Test func deessUnderTheLowestRateNamesTheRate() async throws {
        let (accepted, refused) = (try await Self.package(rate: 4_445), try await Self.package(rate: 4_444))
        let before = (try refused.xml(), DenoiseCommandTests.clips(refused))

        let ok = try await accepted.run("clip", "repair", "PKG", "c1", "--sibilance", "--sibilance-hz", "2000")
        let result = try await refused.run("clip", "repair", "PKG", "c1", "--sibilance", "--sibilance-hz", "2000")

        let file = try DenoiseCommandTests.played("c1", in: accepted)
        #expect(ok == CLIResult(status: 0, stdout: "c1\t\(file.id)\n", stderr: ""), "4445 Hz: \(ok)")
        #expect(result.status == 1 && result.stdout == "", "4444 Hz: \(result)")
        #expect(result.stderr.contains("4445 Hz") && !result.stderr.contains("1999"), "\(result.stderr)")
        let after = (try refused.xml(), DenoiseCommandTests.clips(refused))
        #expect(after == before, "a refused call changed the package")
    }
}
