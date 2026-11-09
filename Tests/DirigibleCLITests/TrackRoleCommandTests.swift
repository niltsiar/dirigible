import DirigibleCore
import Foundation
import Testing

@testable import DirigibleMCP

/// `dirigible track role` and the tool `track_role` (decision 0060, C13).
struct TrackRoleCommandTests {
    let package: TemporaryPackage

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("host", name: "Host", layout: .mono)
        try session.addTrack("bed", name: "Bed", layout: .stereo)
        package = try TemporaryPackage(session)
    }

    private var text: String { get throws { String(decoding: try package.xml(), as: UTF8.self) } }

    /// C13: a role survives a save as version 11 and shows in `info` and `info --json`; `none`
    /// removes it, and the file goes back to version 1.
    @Test func aRoleSurvivesASaveAndShowsInInfo() async throws {
        let silent = CLIResult(status: 0, stdout: "", stderr: "")
        #expect(try await package.run("track", "role", "PKG", "bed", "music") == silent)
        let saved = try text
        #expect(saved.contains(#"version="11""#) && saved.contains(#"role="music""#), "\(saved)")
        let info = try await package.run("info", "PKG")
        #expect(info.stdout.contains(#"track bed "Bed" stereo 0.0 dB role music"#), "\(info.stdout)")
        #expect(!info.stdout.contains(#"track host "Host" mono 0.0 dB role"#), "\(info.stdout)")
        let json = try await package.run("info", "PKG", "--json", "--compact")
        #expect(json.stdout.contains(#""role" : "music""#) && json.stdout.components(separatedBy: "role").count == 2)

        #expect(try await package.run("track", "role", "PKG", "bed", "none") == silent)
        let cleared = try text
        #expect(cleared.contains(#"version="1""#) && !cleared.contains("role"), "\(cleared)")
    }

    /// A word that is not a role exits 64 and changes no byte; an unknown track exits 1.
    @Test func aBadRoleOrTrackChangesNothing() async throws {
        #expect(try await package.run("track", "role", "PKG", "host", "dialogue").status == 0)
        let before = try package.xml()
        let bad = try await package.run("track", "role", "PKG", "host", "voice")
        #expect(bad.status == 64 && bad.stderr.contains("dialogue, music, effects, or none"), "\(bad.stderr)")
        let unknown = try await package.run("track", "role", "PKG", "ghost", "music")
        #expect(unknown.status == 1 && unknown.stderr.contains("ghost"), "\(unknown.stderr)")
        #expect(try package.xml() == before)
    }

    /// The tool sets and clears a role on a closed package, and `session_info` shows it.
    @Test func theToolSetsTheRole() async throws {
        let answers = try await mcp([
            toolCall(1, "track_role", ["package": package.path, "track": "host", "role": "dialogue"]),
            toolCall(2, "session_info", ["package": package.path]),
            toolCall(3, "track_role", ["package": package.path, "track": "host", "role": "voice"]),
        ])
        #expect(toolResult(answer(answers, id: 1)) == ("OK\n" + EditRules.roleReply, false))
        let info = toolResult(answer(answers, id: 2)).text
        #expect(info.contains(#""role":"dialogue""#), "\(info)")
        let bad = toolResult(answer(answers, id: 3))
        #expect(bad.isError && bad.text.contains("must be dialogue or music or effects or none"), "\(bad.text)")
        let saved = try text
        #expect(saved.contains(#"<track id="host" name="Host" gain="0" layout="mono" role="dialogue">"#), "\(saved)")
    }

    /// C2: the help holds the facts in CLI words, the shared text word for word, and a tool name only
    /// in a `(tool ...)` note.
    @Test func theHelpSaysWhatTheRoleDoes() async throws {
        let help = try await dirigible("track", "role", "--help")
        let words = { (text: String) in text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let joined = words(help.stdout)
        for word in ["no sound", "music", "effects", "`clip denoise`", "`info`", "`duck`"] {
            #expect(joined.contains(word), "no \(word): \(help.stdout)")
        }
        #expect(joined.contains(words(EditRules.roleNote)), "the help does not hold roleNote: \(help.stdout)")
        #expect(joined.contains("refuses") && !joined.contains("skips"), "clip denoise refuses a clip: \(help.stdout)")
        let bare = joined.replacing(/\(tool `[a-z_]+`\)/, with: "")
        #expect(!bare.contains("clip_denoise") && !bare.contains("session_info"), "a tool name: \(help.stdout)")
    }

    /// C8: the tool answers `OK` and the line `roleReply` in a batch step; the command prints nothing.
    @Test func aBatchStepAnswersWithTheRoleReply() async throws {
        let call: [String: Any] = ["tool": "track_role", "arguments": ["track": "host", "role": "dialogue"]]
        let answers = try await mcp([toolCall(1, "batch", ["package": package.path, "calls": [call]])])
        let reply = toolResult(answer(answers, id: 1))
        #expect(reply == ("calls[0] track_role: OK\ncalls[0] track_role: " + EditRules.roleReply, false), "\(reply)")
    }
}
