import DirigibleCore
import Foundation
import Testing

/// `dirigible preset set`, `dirigible preset remove`, and the presets in `info` (decision 0080,
/// criterion E10).
struct PresetCommandTests {
    let package: TemporaryPackage

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("host", name: "Host", layout: .mono)
        package = try TemporaryPackage(session)
    }

    private var presets: [ExportPreset] { get throws { try package.read().exportPresets } }
    private var text: String { get throws { String(decoding: try package.xml(), as: UTF8.self) } }
    private let silent = CLIResult(status: 0, stdout: "", stderr: "")

    /// Stores a preset under `name` that the library refuses to add: the name of a built-in. It
    /// writes the preset as `mine` and renames it in `session.xml`, as an older build or a hand edit can.
    private func storeSessionPreset(named name: String, format: ExportFormat) throws {
        try package.edit { session in
            let options = try PresetOptions(format: format, layout: .stereo, rate: .session, loudness: nil)
            try session.setExportPreset(ExportPreset(name: try PresetName("mine"), options: options))
        }
        try text.replacing(#"name="mine""#, with: #"name="\#(name)""#).write(
            to: package.sessionXML, atomically: true, encoding: .utf8)
    }

    @Test func aPresetIsAddedChangedRenamedAndRemoved() async throws {
        let add = try await package.run(
            "preset", "set", "PKG", "Show", "--format", "mp3", "--bitrate", "96", "--mono", "--rate", "44100",
            "--loudness", "podcast")
        #expect(add == silent, "\(add)")
        let saved = try text
        #expect(saved.contains(#"version="20""#), "\(saved)")
        #expect(
            saved.contains(
                #"<preset name="Show" format="mp3" bitRate="96" channels="mono" rate="44100" loudness="podcast"></preset>"#
            ),
            "\(saved)")

        let other = try await package.run("preset", "set", "PKG", "Talk", "--format", "flac")
        #expect(other == silent)
        let change = try await package.run("preset", "set", "PKG", "Show", "--format", "wav", "--bits", "16")
        #expect(change == silent, "an existing name changes that preset in its place: \(change)")
        let wav = try PresetOptions(format: .wav(.bits16), layout: .stereo, rate: .session, loudness: nil)
        #expect(try presets.map(\.name.text) == ["Show", "Talk"])
        #expect(try presets.first?.options == wav)

        let rename = try await package.run("preset", "set", "PKG", "Intro", "--format", "wav", "--rename", "Show")
        #expect(rename == silent, "\(rename)")
        #expect(try presets.map(\.name.text) == ["Intro", "Talk"], "a rename keeps the place")

        #expect(try await package.run("preset", "remove", "PKG", "Intro") == silent)
        #expect(try await package.run("preset", "remove", "PKG", "Talk") == silent)
        let cleared = try text
        #expect(cleared.contains(#"version="1""#) && !cleared.contains("exportPresets"), "\(cleared)")
    }

    /// Each value outside its list exits 64 with its own text, and the package does not change.
    @Test(arguments: [
        (["--format", "ogg"], "--format must be wav, flac, aac, or mp3."),
        (["--format", "wav", "--bits", "20"], "--bits must be 16 or 24."),
        (["--format", "mp3", "--bits", "16"], "--bits is only for wav and flac."),
        (["--format", "wav", "--bitrate", "128"], "--bitrate is only for aac and mp3."),
        (["--format", "aac", "--bitrate", "100"], "--bitrate must be 64, 96, 128, 160, 192, or 256."),
        (["--format", "wav", "--rate", "96000"], "--rate must be 44100 or 48000."),
        (["--format", "wav", "--loudness", "loud"], "--loudness must be podcast, speech, ebu, or atsc."),
    ])
    func eachValueOutsideItsListExitsSixtyFour(options: [String], message: String) async throws {
        let before = try package.xml()

        let result = try await package.run(["preset", "set", "PKG", "Show"] + options)

        #expect(result.status == 64 && result.stdout == "", "\(result)")
        #expect(result.stderr.hasPrefix("Error: \(message)\n"), "\(result.stderr)")
        #expect(try package.xml() == before)
    }

    @Test func aNameThatTheSessionCannotStoreExitsSixtyFour() async throws {
        let before = try package.xml()
        for name in [String(repeating: "a", count: 65), " Show", "A\tB"] {
            let result = try await package.run("preset", "set", "PKG", name, "--format", "wav")
            #expect(result.status == 64 && result.stderr.hasPrefix("Error: the preset name "), "\(result)")
        }
        let missing = try await package.run("preset", "set", "PKG", "Show")
        #expect(missing.status == 64, "--format is required: \(missing)")
        #expect(try package.xml() == before)
    }

    /// A name with the key of a built-in or of another preset exits 1 and changes nothing.
    @Test(arguments: ["Podcast", "MASTER", "show"])
    func aTakenNameExitsOneAndChangesNothing(name: String) async throws {
        #expect(try await package.run("preset", "set", "PKG", "Show", "--format", "wav") == silent)
        let before = try package.xml()

        let result = try await package.run("preset", "set", "PKG", name, "--format", "mp3")

        let text = #"Error: the preset name "\#(name)" is taken by another preset or a built-in preset."# + "\n"
        #expect(result == CLIResult(status: 1, stdout: "", stderr: text), "\(result)")
        #expect(try package.xml() == before)
    }

    @Test func anUnknownPresetExitsOneAndChangesNothing() async throws {
        #expect(try await package.run("preset", "set", "PKG", "Show", "--format", "wav") == silent)
        let before = try package.xml()

        let remove = try await package.run("preset", "remove", "PKG", "ghost")
        let rename = try await package.run("preset", "set", "PKG", "New", "--format", "wav", "--rename", "ghost")

        #expect(remove == CLIResult(status: 1, stdout: "", stderr: "Error: no preset \"ghost\".\n"), "\(remove)")
        #expect(rename == CLIResult(status: 1, stdout: "", stderr: "Error: no preset \"ghost\".\n"), "\(rename)")
        #expect(try package.xml() == before)
    }

    /// E10: a stored preset named "master" (128 kbit/s) changes under its own name, with no key check.
    @Test func aStoredPresetWithABuiltInKeyCanBeSetAgain() async throws {
        try storeSessionPreset(named: "master", format: .mp3(.k128))

        let result = try await package.run("preset", "set", "PKG", "master", "--format", "mp3", "--bitrate", "96")

        #expect(result == silent, "\(result)")
        let stored = try presets
        #expect(stored.map(\.name.text) == ["master"] && stored.first?.options.format == .mp3(.k96), "\(stored)")
    }

    /// E10: a rename to a name with the key of a built-in exits 1, and the package keeps its bytes.
    @Test func aRenameToABuiltInNameExitsOne() async throws {
        #expect(try await package.run("preset", "set", "PKG", "Show", "--format", "mp3") == silent)
        let before = try package.xml()

        let result = try await package.run("preset", "set", "PKG", "podcast", "--format", "mp3", "--rename", "Show")

        let text = "Error: the preset name \"podcast\" is taken by another preset or a built-in preset.\n"
        #expect(result == CLIResult(status: 1, stdout: "", stderr: text), "\(result)")
        #expect(try package.xml() == before)
    }

    /// `info` and `info --json` list the session presets, and leave the key out with none.
    @Test func infoListsThePresets() async throws {
        let (noneJSON, noneText) = (
            try await package.run("info", "PKG", "--json"), try await package.run("info", "PKG")
        )
        #expect(!noneJSON.stdout.contains("exportPresets") && !noneText.stdout.contains("preset"))
        #expect(
            try await package.run(
                "preset", "set", "PKG", "Show", "--format", "mp3", "--bitrate", "96", "--mono", "--rate", "44100",
                "--loudness", "podcast") == silent)
        #expect(try await package.run("preset", "set", "PKG", "Talk", "--format", "flac") == silent)

        let info = try await package.run("info", "PKG")
        #expect(
            info.stdout.contains(
                #"preset "Show" format mp3 bitrate 96 channels mono rate 44100 loudness podcast"# + "\n"
                    + #"preset "Talk" format flac bits 24 channels stereo rate session"# + "\n"), "\(info.stdout)")
        let json = try await package.run("info", "PKG", "--json")
        #expect(json.stdout.contains(#""exportPresets" : ["#), "\(json.stdout)")
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        let list = try #require(object["exportPresets"] as? [[String: Any]])
        #expect(list.count == 2 && list[0]["name"] as? String == "Show" && list[0]["bitRate"] as? Int == 96)
        #expect(list[0]["bits"] == nil && list[0]["loudness"] as? String == "podcast")
        #expect(list[1]["bits"] as? Int == 24 && list[1]["loudness"] == nil && list[1]["rate"] as? String == "session")
    }
}
