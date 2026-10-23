import DirigibleCore
import Foundation
import Testing

extension ExportCommandTests {
    /// An episode with a title, so that an MP3 or M4A export of it prints no title warning.
    static func titledEpisode() throws -> Episode {
        var episode = Episode()
        episode.title = try EpisodeLine("Episode 1")
        return episode
    }

    /// C18: an MP3 or M4A export of an episode with no title prints one warning line on stderr,
    /// after the other warning lines. A WAV export and an export with a title print none.
    @Test func noTitleWarnsOnStderr() async throws {
        func line(_ file: URL) -> String {
            "Warning: the episode has no title, so \(file.path) has no title tag. Set it with "
                + "`dirigible episode set --title <title> <package>`.\n"
        }
        try package.edit { $0.setEpisode(Episode()) }
        for name in ["a.mp3", "a.m4a"] {
            #expect(
                try await package.run("export", "PKG", "--out", out(name).path)
                    == CLIResult(status: 0, stdout: "", stderr: line(out(name))), "\(name)")
        }
        #expect(
            try await package.run("export", "PKG", "--out", out("a.wav").path)
                == CLIResult(status: 0, stdout: "", stderr: ""), "a WAV file has no title tag")

        try package.edit { try $0.setMuted(true, tracks: ["t2"]) }
        let muted = "Warning: 1 track is muted or not soloed and is not in the export.\n"
        #expect(
            try await package.run("export", "PKG", "--out", out("b.mp3").path)
                == CLIResult(status: 0, stdout: "", stderr: muted + line(out("b.mp3"))), "the title line is last")

        try package.edit { session in
            var episode = session.episode
            episode.title = try EpisodeLine("Episode 1")
            session.setEpisode(episode)
        }
        #expect(
            try await package.run("export", "PKG", "--out", out("c.mp3").path)
                == CLIResult(status: 0, stdout: "", stderr: muted), "a title silences the line")
    }
}
