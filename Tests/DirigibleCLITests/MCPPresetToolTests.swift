import DirigibleCore
import Foundation
import Testing

@testable import DirigibleMCP

/// The tools `preset_set` and `preset_remove` on the files (decision 0080, criterion E10). Each one
/// gives the result and the texts of its command, with `bitrate` in place of `--bitrate`.
struct MCPPresetToolTests {
    let package: TemporaryPackage

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("host", name: "Host", layout: .mono)
        package = try TemporaryPackage(session)
    }

    private func call(_ tool: String, _ arguments: [String: Any]) async throws -> (text: String, isError: Bool) {
        let answers = try await mcp([toolCall(1, tool, ["package": package.path].merging(arguments) { $1 })])
        return toolResult(answer(answers, id: 1))
    }

    @Test func theToolsSetChangeRenameAndRemoveAPreset() async throws {
        let add = try await call(
            "preset_set",
            ["name": "Show", "format": "mp3", "bitrate": 96, "mono": true, "rate": 44_100, "loudness": "podcast"])
        #expect(add == ("OK", false), "\(add)")
        let options = try PresetOptions(format: .mp3(.k96), layout: .mono, rate: .hz44100, loudness: .podcast)
        #expect(try package.read().exportPresets == [ExportPreset(name: try PresetName("Show"), options: options)])

        let info = try await call("session_info", [:])
        let key =
            #""exportPresets":[{"bitRate":96,"channels":"mono","format":"mp3","loudness":"podcast","name":"Show","rate":"44100"}]"#
        #expect(info.text.contains(key), "\(info.text)")

        let rename = try await call("preset_set", ["name": "Intro", "format": "flac", "bits": 16, "rename": "Show"])
        #expect(rename == ("OK", false), "\(rename)")
        let renamed = try package.read().exportPresets
        #expect(renamed.map(\.name.text) == ["Intro"] && renamed.first?.options.format == .flac(.bits16))

        #expect(try await call("preset_remove", ["name": "Intro"]) == ("OK", false))
        #expect(try package.read().exportPresets.isEmpty)
    }

    /// The texts are the texts of the command, with the tool name of each option.
    @Test(
        arguments: [
            (["name": "Show", "format": "ogg"], "format must be wav, flac, aac, or mp3."),
            (["name": "Show", "format": "wav", "bits": 20], "bits must be 16 or 24."),
            (["name": "Show", "format": "mp3", "bits": 16], "bits is only for wav and flac."),
            (["name": "Show", "format": "wav", "bitrate": 128], "bitrate is only for aac and mp3."),
            (["name": "Show", "format": "aac", "bitrate": 100], "bitrate must be 64, 96, 128, 160, 192, or 256."),
            (["name": "Show", "format": "wav", "rate": 96_000], "rate must be 44100 or 48000."),
            (["name": "Show", "format": "wav", "loudness": "loud"], "loudness must be podcast, speech, ebu, or atsc."),
            (
                ["name": "Podcast", "format": "mp3"],
                "the preset name \"Podcast\" is taken by another preset or a built-in preset."
            ),
            (
                ["name": " Show", "format": "mp3"],
                "the preset name \" Show\" must have 1 to 64 characters, no space at either end, and no control character."
            ),
        ] as [([String: any Sendable], String)])
    func eachRefusalHasItsText(arguments: [String: any Sendable], message: String) async throws {
        let before = try package.xml()

        let result = try await call("preset_set", arguments)

        #expect(result == (message, true), "\(result)")
        #expect(try package.xml() == before)
    }

    @Test func anUnknownPresetIsRefused() async throws {
        let remove = try await call("preset_remove", ["name": "ghost"])
        let rename = try await call("preset_set", ["name": "New", "format": "wav", "rename": "ghost"])

        #expect(remove == ("no preset \"ghost\".", true) && rename == ("no preset \"ghost\".", true))
    }

    /// The agent can set a preset again under its own name, also when it has the key of a built-in.
    @Test func aStoredPresetWithABuiltInKeyCanBeSetAgain() async throws {
        try package.edit { session in
            let options = try PresetOptions(format: .mp3(.k128), layout: .stereo, rate: .session, loudness: nil)
            try session.setExportPreset(ExportPreset(name: try PresetName("mine"), options: options))
        }
        let text = try String(contentsOf: package.sessionXML, encoding: .utf8)
        try text.replacing(#"name="mine""#, with: #"name="master""#).write(
            to: package.sessionXML, atomically: true, encoding: .utf8)

        let result = try await call("preset_set", ["name": "master", "format": "mp3", "bitrate": 96])

        #expect(result == ("OK", false), "\(result)")
        #expect(try package.read().exportPresets.first?.options.format == .mp3(.k96))
    }
}
