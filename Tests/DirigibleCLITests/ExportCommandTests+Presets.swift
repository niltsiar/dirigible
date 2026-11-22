import DirigibleCore
import Foundation
import Testing

/// `dirigible export --preset` (decision 0080, criterion E11). The package of `ExportCommandTests`:
/// the session rate is 48 000 Hz and the mix is stereo. `--out` is `<folder>/<prefix>`.
extension ExportCommandTests {
    func prefixOut(_ prefix: String = "Ep") -> String { out(prefix).path }

    /// Writes the session preset `name` as `mine`, then renames it in `session.xml`: a hand edit that
    /// gives a stored name the key of a built-in, which the library refuses to add.
    func storeShadow(named name: String) throws {
        try package.edit { session in
            let options = try PresetOptions(format: .flac(.bits16), layout: .mono, rate: .session, loudness: nil)
            try session.setExportPreset(ExportPreset(name: try PresetName("mine"), options: options))
        }
        let text = try String(contentsOf: package.sessionXML, encoding: .utf8)
        try text.replacing(#"name="mine""#, with: #"name="\#(name)""#).write(
            to: package.sessionXML, atomically: true, encoding: .utf8)
    }

    @Test func masterAndPodcastWriteTwoFilesAndTwoLines() async throws {
        let result = try await package.run(
            "export", "PKG", "--preset", "master", "--preset", "podcast", "--out", prefixOut())

        let lines = result.stdout.split(separator: "\n").map(String.init)
        #expect(result.status == 0 && result.stderr == "" && lines.count == 2, "\(result)")
        #expect(lines.first == out("Ep.wav").path, "the master preset has no loudness target: \(lines)")
        let podcast = try #require(lines.last)
        #expect(podcast.hasPrefix(out("Ep.mp3").path + "\tloudness -19."), "the podcast target is -19 LUFS: \(podcast)")
        #expect(try names() == ["Ep.mp3", "Ep.wav", "Show.dirigible"])
        let master = try facts(out("Ep.wav"))
        #expect(master.channels == 2 && master.rate == 48_000 && master.frames == 21_000, "\(master)")
        let mp3 = try facts(out("Ep.mp3"))
        #expect(mp3.channels == 1 && mp3.rate == 44_100, "\(mp3)")
    }

    /// Each option that a preset sets, and an `--out` that names a file format, exits 64 and writes nothing.
    @Test(arguments: [
        (["--bits", "16"], "--bits"), (["--bitrate", "96"], "--bitrate"), (["--mono"], "--mono"),
        (["--rate", "44100"], "--rate"), (["--loudness", "podcast"], "--loudness"),
        (["--split", "chapters"], "--split"),
    ])
    func aPresetWithAnOptionOfItsOwnExitsSixtyFour(option: [String], name: String) async throws {
        let result = try await package.run(
            ["export", "PKG", "--preset", "master", "--out", prefixOut()] + option)

        #expect(result.status == 64, "\(result)")
        #expect(
            result.stderr.hasPrefix("Error: --preset sets the options of each file, so it cannot go with \(name).\n"),
            "\(result.stderr)")
        #expect(try names() == ["Show.dirigible"])
    }

    @Test(arguments: ["wav", "m4a", "mp3", "flac"])
    func anOutWithAFileExtensionExitsSixtyFour(pathExtension: String) async throws {
        let result = try await package.run(
            "export", "PKG", "--preset", "master", "--out", out("Ep.\(pathExtension)").path)

        #expect(result.status == 64, "\(result)")
        #expect(
            result.stderr.hasPrefix(
                "Error: --out is the folder and the file name prefix of the presets, so it must not end in .wav, "
                    + ".m4a, .mp3, or .flac.\n"), "\(result.stderr)")
        #expect(try names() == ["Show.dirigible"])
    }

    /// An `--out` that ends in / or names a folder exits 64 and writes no file, also not in the parent folder.
    @Test(arguments: ["", "/"])
    func anOutThatIsAFolderExitsSixtyFour(end: String) async throws {
        try FileManager.default.createDirectory(at: out("Ep"), withIntermediateDirectories: false)
        let result = try await package.run("export", "PKG", "--preset", "master", "--out", out("Ep").path + end)

        #expect(result.status == 64, "\(result)")
        #expect(
            result.stderr.hasPrefix(
                "Error: --out is <folder>/<prefix> for the presets, so it must not end in / or name a folder.\n"),
            "\(result.stderr)")
        #expect(try names() == ["Ep", "Show.dirigible"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: out("Ep").path).isEmpty)
    }

    @Test func aDotInThePrefixIsPartOfThePrefix() async throws {
        let result = try await package.run("export", "PKG", "--preset", "master", "--out", prefixOut("Ep.1"))

        #expect(result.status == 0, "\(result)")
        #expect(try names() == ["Ep.1.wav", "Show.dirigible"])
    }

    /// An unknown preset gives the exit and the text form of an unknown `--track`.
    @Test func anUnknownPresetExitsSixtyFourWithTheTrackForm() async throws {
        let result = try await package.run("export", "PKG", "--preset", "ghost", "--out", prefixOut())

        #expect(result.status == 64 && result.stdout == "", "\(result)")
        #expect(result.stderr.hasPrefix("Error: The session has no preset ghost.\n"), "\(result.stderr)")
        #expect(try names() == ["Show.dirigible"])
    }

    /// A stored name that has the key of a built-in wins: `--preset Master` writes its options.
    @Test func aShadowedNameExportsTheSessionPreset() async throws {
        try storeShadow(named: "master")

        let result = try await package.run("export", "PKG", "--preset", "Master", "--out", prefixOut())

        #expect(result == CLIResult(status: 0, stdout: out("Ep.flac").path + "\n", stderr: ""), "\(result)")
        #expect(try names() == ["Ep.flac", "Show.dirigible"], "not the WAV of the built-in")
        let flac = try facts(out("Ep.flac"))
        #expect(flac.channels == 1, "the stored preset is mono: \(flac)")
    }

    /// Two files of one extension get the preset name in the file name.
    @Test func twoPresetsOfOneFormatNameTheirFiles() async throws {
        try storeShadow(named: "Solo")

        let result = try await package.run(
            "export", "PKG", "--preset", "Solo", "--preset", "master", "--preset", "podcast", "--out", prefixOut())

        #expect(result.status == 0 && result.stdout.split(separator: "\n").count == 3, "\(result)")
        #expect(try names() == ["Ep.flac", "Ep.mp3", "Ep.wav", "Show.dirigible"], "one file for each extension")
    }

    @Test func aPresetGivenTwiceRefusesBeforeAnyFile() async throws {
        let result = try await package.run(
            "export", "PKG", "--preset", "podcast", "--preset", "Podcast", "--out", prefixOut())

        let text =
            "Error: Two presets or more would write one file: \(out("Ep-podcast.mp3").path). "
            + "Give each preset once, or rename a preset.\n"
        #expect(result == CLIResult(status: 2, stdout: "", stderr: text), "\(result)")
        #expect(try names() == ["Show.dirigible"])
    }

    @Test func anExistingFileExitsTwoUntilReplace() async throws {
        let old = out("Ep.mp3")
        try Data("keep".utf8).write(to: old)

        let refused = try await package.run(
            "export", "PKG", "--preset", "master", "--preset", "podcast", "--out", prefixOut())

        let text = "Error: 1 file exists: \(old.path). Use --replace to replace it.\n"
        #expect(refused == CLIResult(status: 2, stdout: "", stderr: text), "\(refused)")
        #expect(try names() == ["Ep.mp3", "Show.dirigible"], "no file of the set is written")

        let replaced = try await package.run(
            "export", "PKG", "--preset", "master", "--preset", "podcast", "--out", prefixOut(), "--replace")
        #expect(replaced.status == 0, "\(replaced)")
        #expect(try facts(old).channels == 1, "the old file is the new MP3")
        #expect(try names() == ["Ep.mp3", "Ep.wav", "Show.dirigible"])
    }

    @Test func aFileThatIsMissingRefusesTheSet() async throws {
        try package.edit { session in
            try session.place(Clip(id: "c2", file: "gone", start: 0, offset: 0, length: 500), on: "t2")
        }

        let result = try await package.run("export", "PKG", "--preset", "master", "--out", prefixOut())

        #expect(result.status == 2 && result.stderr.hasPrefix("Error: file gone "), "\(result)")
        #expect(try names() == ["Show.dirigible"])
    }

    /// A 96 000 Hz session with the MP3 preset "Feed" at the session rate, a rate that MP3 cannot write,
    /// and an old `Ep.mp3` at its target. The clip names a file that is not on disk.
    static func highRatePackage() throws -> TemporaryPackage {
        var session = Session(sampleRate: 96_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 20_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 20_000), on: "t1")
        let options = try PresetOptions(format: .mp3(.k128), layout: .mono, rate: .session, loudness: nil)
        try session.setExportPreset(ExportPreset(name: try PresetName("Feed"), options: options))
        let package = try TemporaryPackage(session)
        try Data("old".utf8).write(to: package.folder.appending(path: "Ep.mp3"))
        return package
    }

    /// The rate refusal names the preset and comes before the media check and the check of the targets.
    @Test func aRateThatAPresetCannotWriteExitsTwoBeforeTheTargetCheck() async throws {
        let package = try Self.highRatePackage()

        let result = try await package.run(
            "export", "PKG", "--preset", "Feed", "--out", package.folder.appending(path: "Ep").path)

        let text = "Error: preset \"Feed\" cannot write 96000 Hz. Set another rate with `dirigible preset set`.\n"
        #expect(result == CLIResult(status: 2, stdout: "", stderr: text), "\(result)")
        #expect(try Data(contentsOf: package.folder.appending(path: "Ep.mp3")) == Data("old".utf8))
    }
}
