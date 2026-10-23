import DirigibleAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleMCP

/// The one owner of the texts of `export` and `render`. `ExportCommandTests` pins the same texts
/// through the command.
struct ExportTextTests {
    /// Each option rule gives the text of the command (`ExportCommandTests.eachRefusalHasItsText`).
    @Test(arguments: [
        (["x.wav", "", "128", "", ""], "--bitrate is only for .m4a and .mp3."),
        (["x.flac", "20", "", "", ""], "--bits must be 16 or 24."),
        (["x.mp3", "16", "", "", ""], "--bits is only for .wav and .flac."),
        (["x.m4a", "", "100", "", ""], "--bitrate must be 64, 96, 128, 160, 192, or 256."),
        (["x.ogg", "", "", "", ""], "--out must end in .wav, .m4a, .mp3, or .flac."),
        (["x.wav", "", "", "96000", ""], "--rate must be 44100 or 48000."),
        (["x.wav", "", "", "", "loud"], "--loudness must be podcast, speech, ebu, or atsc."),
    ])
    func theOptionsRefuseWhatTheCommandRefuses(fields: [String], text: String) {
        let error = #expect(throws: ToolError.self) {
            try ExportText.options(
                out: fields[0], bits: Int(fields[1]), bitrate: Int(fields[2]), mono: false, rate: Int(fields[3]),
                loudness: fields[4].isEmpty ? nil : fields[4], spelling: .cli)
        }
        #expect(error?.message == text, "the option text")
    }

    /// Code gate 2 item 5: the tool spelling of each option rule names the tool argument.
    @Test(arguments: [
        (["x.wav", "", "128", "", ""], "bitrate is only for .m4a and .mp3."),
        (["x.flac", "20", "", "", ""], "bits must be 16 or 24."),
        (["x.mp3", "16", "", "", ""], "bits is only for .wav and .flac."),
        (["x.m4a", "", "100", "", ""], "bitrate must be 64, 96, 128, 160, 192, or 256."),
        (["x.ogg", "", "", "", ""], "out must end in .wav, .m4a, .mp3, or .flac."),
        (["x.wav", "", "", "96000", ""], "rate must be 44100 or 48000."),
        (["x.wav", "", "", "", "loud"], "loudness must be podcast, speech, ebu, or atsc."),
    ])
    func theToolOptionsNameTheArguments(fields: [String], text: String) {
        let error = #expect(throws: ToolError.self) {
            try ExportText.options(
                out: fields[0], bits: Int(fields[1]), bitrate: Int(fields[2]), mono: false, rate: Int(fields[3]),
                loudness: fields[4].isEmpty ? nil : fields[4], spelling: .tool)
        }
        #expect(error?.message == text, "the option text")
    }

    /// Code gate 2 item 5: each other text that names an option or a command has a tool spelling
    /// with no CLI option and no `dirigible` command.
    @Test func theToolTextsNameTheArgumentsAndTools() {
        var session = Session(sampleRate: 48_000)
        try? session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 100))
        let faults: [FileID: MediaFault] = ["f1": .missing]
        let chapter = Marker(id: "c1", name: "One", position: 0, kind: .chapter)
        let texts = [
            ExportText.rangeMessage(end: 100, spelling: .tool),
            ExportText.faultMessage(faults, in: session, spelling: .tool),
            ExportText.readFaultMessage(faults, in: session, out: "mix.wav", spelling: .tool),
            ExportText.rateMessage(out: "mix.m4a", rate: 96_000, spelling: .tool),
            ExportText.failureMessage(.artworkMissing("art.png"), out: "mix.mp3", noun: "export", spelling: .tool),
            ExportText.failureMessage(
                .chapterImageMissing(chapter, rate: 48_000), out: "mix.mp3", noun: "export", spelling: .tool),
        ]
        let words = [
            "with to more than from;", "Use allow_missing to export", "Use allow_missing to accept",
            "Use rate 44100 or rate 48000.", "the episode_set tool and artwork",
            "the marker_set tool, id c1, and image",
        ]
        for (text, word) in zip(texts, words) {
            #expect(text?.contains(word) == true, "\(word) is not in: \(text ?? "nil")")
            #expect(text?.contains("--") == false && text?.contains("dirigible ") == false, "a CLI name: \(text ?? "")")
        }
    }

    /// C18: an MP3 or M4A file of an episode with no title gets a warning line, in the spelling of
    /// the caller. A WAV or FLAC file and an episode with a title get none.
    @Test func anMP3OrM4AWithNoTitleWarns() throws {
        var session = Session(sampleRate: 48_000)
        let file = URL(filePath: "/out/mix.mp3")
        let tool =
            "Warning: the episode has no title, so /out/mix.mp3 has no title tag. Set it with episode_set and title."
        let cli =
            "Warning: the episode has no title, so /out/mix.mp3 has no title tag. Set it with "
            + "`dirigible episode set --title <title> <package>`."
        for format: ExportFormat in [.mp3(.k128), .aac(.k128)] {
            #expect(
                ExportText.titleLines(session, format: format, output: file, spelling: .tool) == [tool], "\(format)")
            #expect(ExportText.titleLines(session, format: format, output: file, spelling: .cli) == [cli])
        }
        for format: ExportFormat in [.wav(.bits24), .flac(.bits24)] {
            #expect(ExportText.titleLines(session, format: format, output: file, spelling: .tool) == [], "\(format)")
        }
        var episode = Episode()
        episode.title = try EpisodeLine("Episode 1")
        session.setEpisode(episode)
        for format: ExportFormat in [.mp3(.k128), .aac(.k128)] {
            #expect(ExportText.titleLines(session, format: format, output: file, spelling: .tool) == [], "\(format)")
        }
    }

    /// Code gate item E6. The MP3 chapter limit is a limit with an action, in ms and in days.
    @Test func theMP3ChapterLimitGivesTheLimitAndAnAction() {
        #expect(
            ExportText.failureMessage(.chaptersTooLong, out: "mix.mp3", noun: "export", spelling: .cli)
                == "an MP3 file with chapters holds at most 4294967295 ms (about 49.7 days). Export a shorter range.")
    }

    /// C19: a file in any package is refused, also in a package that is not the one of the call.
    /// A file beside a package passes.
    @Test func anOutInsideAPackageIsRefused() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(
            at: folder.appending(path: "Other.dirigible/Clips"), withIntermediateDirectories: true)

        #expect(throws: Never.self, "a file beside a package") {
            try ExportText.checkOutsidePackages(folder.appending(path: "show.wav"))
        }
        let error = #expect(throws: ToolError.self, "a file in a package") {
            try ExportText.checkOutsidePackages(folder.appending(path: "Other.dirigible/Clips/take.wav"))
        }
        #expect(error?.message == "The output file must be outside the session package.")
    }

    /// C19: a link to a folder in a package does not hide the package.
    @Test func anOutThroughALinkIntoAPackageIsRefused() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clips = folder.appending(path: "Show.dirigible/Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "link"), withDestinationURL: clips)

        #expect(throws: ToolError.self, "a file through a link") {
            try ExportText.checkOutsidePackages(folder.appending(path: "link/take.wav"))
        }
    }

    /// C19: the package extension compares with no case.
    @Test func anOutInAnUpperCasePackageIsRefused() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = folder.appending(path: "Show.DIRIGIBLE")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)

        #expect(throws: ToolError.self, "a file in an upper-case package") {
            try ExportText.checkOutsidePackages(package.appending(path: "x.wav"))
        }
    }
}

/// A new empty folder in the temporary folder. The caller removes it.
private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ExportTextTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}
