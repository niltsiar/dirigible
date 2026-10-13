import DirigibleAudio
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
                loudness: fields[4].isEmpty ? nil : fields[4])
        }
        #expect(error?.message == text, "the option text")
    }

    /// Code gate item E6. The MP3 chapter limit is a limit with an action, in ms and in days.
    @Test func theMP3ChapterLimitGivesTheLimitAndAnAction() {
        #expect(
            ExportText.failureMessage(.chaptersTooLong, out: "mix.mp3", noun: "export")
                == "an MP3 file with chapters holds at most 4294967295 ms (about 49.7 days). Export a shorter range.")
    }
}
