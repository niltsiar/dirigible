import AVFoundation
import CryptoKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// `dirigible import` (decision 0040, run 13a criteria C3 d, C4 a, and C8). Track T (mono).
struct ImportCommandTests {
    static func package() throws -> TemporaryPackage {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("T", name: "Host", layout: .mono)
        return try TemporaryPackage(session)
    }

    /// Writes `samples` (mono) at `rate` Hz to `url` as `format`.
    static func write(_ url: URL, _ format: ExportFormat, rate: Int = 44_100, _ samples: [Float]) throws {
        let client = try #require(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: client, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        buffer.floatChannelData![0].update(from: samples, count: samples.count)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        try writeFile(url, format: format, rate: rate, client: client) { write throws(ExportError) in try write(buffer)
        }
    }

    /// 1 s of a 1 kHz sine at amplitude 0.25.
    static let quiet = (0..<44_100).map { Float(0.25 * sin(2 * Double.pi * 1000 * Double($0) / 44_100)) }
    /// A full-scale square: its peak after the rate change is over 1, so the conversion scales it.
    static let loud = (0..<44_100).map { Float(($0 / 50) % 2 == 0 ? 1 : -1) }

    /// The SHA-256 of each file in the package, by path.
    static func hashes(_ package: TemporaryPackage) throws -> [String: SHA256.Digest] {
        let files = FileManager.default.enumerator(atPath: package.path)?.compactMap { $0 as? String } ?? []
        var result: [String: SHA256.Digest] = [:]
        for file in files {
            let url = package.url.appending(path: file)
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            result[file] = SHA256.hash(data: data)
        }
        return result
    }

    @Test func importPrintsTheClipIDAndAddsTheClip() async throws {
        let package = try Self.package()
        let source = package.folder.appending(path: "Intro.mp3")
        try Self.write(source, .mp3(.k192), Self.quiet)

        let result = try await package.run("import", "PKG", source.path, "--track", "T", "--at", "48000")

        #expect(result == CLIResult(status: 0, stdout: "Intro\n", stderr: ""), "import: \(result)")
        let session = try package.read()
        #expect(session.clip("Intro")?.track == "T" && session.clip("Intro")?.clip.start == 48_000)
        #expect(session.files["Intro"]?.path == "Intro.wav" && session.files["Intro"]?.capture == nil)
        let gain = try #require(session.clip("Intro")?.clip.gain.dB)
        #expect(abs(gain) > 1, "the clip is leveled: \(gain) dB")
    }

    @Test func noTrackGivesANewTrackNamedAfterTheFile() async throws {
        let package = try Self.package()
        let source = package.folder.appending(path: "Guest.flac")
        try Self.write(source, .flac(.bits16), Self.quiet)

        let result = try await package.run("import", "PKG", source.path)

        #expect(result.status == 0, "import: \(result)")
        let session = try package.read()
        let track = try #require(session.tracks.last)
        #expect(session.tracks.count == 2 && track.name == "Guest" && track.layout == .mono)
        #expect(session.clip("Guest")?.track == track.id && session.clip("Guest")?.clip.start == 0)
    }

    @Test func noLevelKeepsTheGainOfTheConversion() async throws {
        let package = try Self.package()
        let (quiet, loud) = (package.folder.appending(path: "quiet.wav"), package.folder.appending(path: "loud.wav"))
        try Self.write(quiet, .wav(.bits24), Self.quiet)
        try Self.write(loud, .wav(.bits24), Self.loud)

        let first = try await package.run("import", "PKG", quiet.path, "--track", "T", "--no-level")
        let second = try await package.run("import", "PKG", loud.path, "--track", "T", "--at", "96000", "--no-level")

        #expect(first.status == 0 && second.status == 0, "import: \(first) \(second)")
        let session = try package.read()
        #expect(session.clip("quiet")?.clip.gain == .zero, "a quiet file keeps 0 dB")
        let gain = try #require(session.clip("loud")?.clip.gain.dB)
        #expect(gain > 0.1, "a loud file keeps the gain of the second pass: \(gain) dB")
    }

    @Test func aRefusalKeepsEveryByte() async throws {
        let package = try Self.package()
        let source = package.folder.appending(path: "Intro.wav")
        try Self.write(source, .wav(.bits16), Self.quiet)
        let text = package.folder.appending(path: "notes.mp3")
        try Data("hello".utf8).write(to: text)
        // The first edit makes the lock file (decision 0012).
        FileManager.default.createFile(atPath: package.url.appending(path: ".lock").path, contents: nil)
        let before = try Self.hashes(package)

        let unknown = try await package.run("import", "PKG", source.path, "--track", "nope")
        let negative = try await package.run("import", "PKG", source.path, "--at", "-1")
        let notAudio = try await package.run("import", "PKG", text.path)

        #expect(unknown == CLIResult(status: 1, stdout: "", stderr: "Error: no track \"nope\".\n"), "\(unknown)")
        #expect(negative.status == 1 && negative.stderr.hasPrefix("Error: a frame"), "\(negative)")
        #expect(
            notAudio
                == CLIResult(
                    status: 1, stdout: "", stderr: "Error: \(text.path) is not an audio file that Dirigible can read.\n"
                ),
            "\(notAudio)")
        let after = try Self.hashes(package)
        #expect(after == before, "a refusal changes no byte and adds no file: \(after.keys.sorted())")
    }

    @Test func aLockedPackageAndAPendingTakeExit2() async throws {
        let package = try Self.package()
        let source = package.folder.appending(path: "Intro.wav")
        try Self.write(source, .wav(.bits16), Self.quiet)
        let locked: CLIResult
        do {
            let lock = try PackageLock(package.url)
            locked = try await package.run("import", "PKG", source.path)
            withExtendedLifetime(lock) {}
        }
        try package.edit { session in
            try session.setRecording(
                Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 1, armedTracks: ["T"]))
        }
        let pending = try await package.run("import", "PKG", source.path)

        #expect(locked == CLIResult(status: 2, stdout: "", stderr: "Error: \(package.path) is open in Dirigible.\n"))
        #expect(pending.status == 2 && pending.stderr.contains("not finalized"), "\(pending)")
    }

    /// `--id` names the clip; the file ID and the WAV keep the stem.
    @Test func anImportWithAnIDNamesOnlyTheClip() async throws {
        let package = try Self.package()
        let source = package.folder.appending(path: "Intro.wav")
        try Self.write(source, .wav(.bits16), Self.quiet)

        let result = try await package.run("import", "PKG", source.path, "--track", "T", "--id", "Sting")

        #expect(result == CLIResult(status: 0, stdout: "Sting\n", stderr: ""), "import: \(result)")
        let session = try package.read()
        #expect(session.clip("Sting")?.clip.file == "Intro" && session.files["Intro"]?.path == "Intro.wav")
        #expect(session.clip("Intro") == nil, "no clip has the stem")
        let names = try FileManager.default.contentsOfDirectory(atPath: package.url.appending(path: "Clips").path)
        #expect(names == ["Intro.wav"], "\(names)")
    }

    /// An `--id` that a clip uses refuses, and no file is made.
    @Test func anImportWithAUsedClipIDWritesNoFile() async throws {
        let package = try Self.package()
        let (first, second) = (package.folder.appending(path: "Intro.wav"), package.folder.appending(path: "Outro.wav"))
        try Self.write(first, .wav(.bits16), Self.quiet)
        try Self.write(second, .wav(.bits16), Self.quiet)
        #expect(try await package.run("import", "PKG", first.path, "--track", "T").status == 0)
        let before = try Self.hashes(package)

        let used = try await package.run("import", "PKG", second.path, "--track", "T", "--id", "Intro")

        #expect(
            used == CLIResult(status: 1, stdout: "", stderr: "Error: the ID \"Intro\" is already used.\n"), "\(used)")
        let after = try Self.hashes(package)
        #expect(after == before, "a refusal changes no byte and adds no file: \(after.keys.sorted())")
    }

    /// A frame or a length out of its range exits 64; a range or fades past
    /// the made WAV exit 1. Each refusal keeps every byte.
    @Test func aShapeOutOfRangeChangesNothing() async throws {
        let package = try Self.package()
        let source = package.folder.appending(path: "Intro.wav")
        try Self.write(source, .wav(.bits16), Self.quiet)
        FileManager.default.createFile(atPath: package.url.appending(path: ".lock").path, contents: nil)
        let before = try Self.hashes(package)
        let past = String((1 << 40) + 1)

        for options in [
            ["--offset=-1"], ["--length", "0"], ["--offset", past], ["--length", past], ["--fade-in=-1"],
            ["--fade-out", past],
        ] {
            let result = try await package.run(["import", "PKG", source.path, "--track", "T"] + options)
            #expect(result.status == 64 && result.stdout.isEmpty, "\(options): \(result)")
        }
        let atEnd = try await package.run("import", "PKG", source.path, "--track", "T", "--offset", "96000")
        let faded = try await package.run(
            "import", "PKG", source.path, "--track", "T", "--fade-in", "30000", "--fade-out", "30000")

        #expect(atEnd == CLIResult(status: 1, stdout: "", stderr: "Error: clip \"Intro\" is not inside its file.\n"))
        #expect(faded.status == 1 && faded.stderr.hasPrefix("Error: the fades and crossfades of clip"), "\(faded)")
        let after = try Self.hashes(package)
        #expect(after == before, "a refusal changes no byte and adds no file: \(after.keys.sorted())")
    }

    /// The help gives the unit of `--offset` and `--length`.
    @Test func helpGivesTheUnitOfTheRange() async throws {
        let help = try await dirigible("import", "--help")
        let text = help.stdout.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for words in ["--id", "--offset", "--length", "--db", "--fade-in", "--fade-out", "frames of the made WAV"] {
            #expect(text.contains(words), "help has no \(words)")
        }
    }

    @Test func helpNamesTheOptions() async throws {
        let help = try await dirigible("import", "--help")
        #expect(help.status == 0)
        for text in ["--track", "--at", "--no-level", "WAV, AIFF, FLAC, MP3, and M4A"] {
            #expect(help.stdout.contains(text), "help has no \(text)")
        }
    }
}
