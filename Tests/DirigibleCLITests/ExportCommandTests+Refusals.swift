import Foundation
import Testing

/// The refusals of `dirigible export` and `dirigible render`. The MCP tools give the same texts
/// (decision 0041), so these tests pin each text byte for byte.
extension ExportCommandTests {
    /// Each refused argument gives exit 64, its own text, and no output file.
    @Test(arguments: [
        (["export", "--out", "x.wav", "--bitrate", "128"], "--bitrate is only for .m4a and .mp3."),
        (["export", "--out", "x.flac", "--bits", "20"], "--bits must be 16 or 24."),
        (["export", "--out", "x.mp3", "--bits", "16"], "--bits is only for .wav and .flac."),
        (["export", "--out", "x.m4a", "--bitrate", "100"], "--bitrate must be 64, 96, 128, 160, 192, or 256."),
        (["export", "--out", "x.ogg"], "--out must end in .wav, .m4a, .mp3, or .flac."),
        (["export", "--out", "x.wav", "--rate", "96000"], "--rate must be 44100 or 48000."),
        (["export", "--out", "x.wav", "--loudness", "loud"], "--loudness must be podcast, speech, ebu, or atsc."),
        (["export", "--out", "x.wav", "--track", "t9"], "The session has no track t9."),
        (
            ["export", "--out", "x.wav", "--from", "21000"],
            "The range must be 0 or more, with --to more than --from; the session end is 21000."
        ),
        (
            ["render", "--out", "x.caf", "--from", "5", "--to", "5"],
            "The range must be 0 or more, with --to more than --from; the session end is 21000."
        ),
    ])
    func eachRefusalHasItsText(arguments: [String], text: String) async throws {
        let file = out(arguments[2])
        var command = arguments
        command[2] = file.path
        command.insert("PKG", at: 1)

        let result = try await package.run(command)

        #expect(result.status == 64, "the exit of \(arguments)")
        #expect(result.stderr.hasPrefix("Error: \(text)\n"), "the refusal text: \(result.stderr)")
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
