import DirigibleAudio
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
