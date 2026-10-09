import DirigibleCore
import Foundation
import Testing

/// `dirigible chapters export` (run 2026-10-09-chapters-export, criteria C9 to C12). Track `t1`
/// has a clip at 0..<960 000, so the session ends at 20 s; chapters at 10 s and 12 s.
struct ChaptersCommandTests {
    let package: TemporaryPackage

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 960_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 960_000), on: "t1")
        try session.setMarker(Marker(id: "a", name: "Interview", position: 480_000, kind: .chapter))
        try session.setMarker(Marker(id: "b", name: "Outro", position: 576_000, kind: .chapter))
        package = try TemporaryPackage(session)
    }

    func out(_ name: String) -> URL { package.folder.appending(path: name) }

    /// The `startTime` values of a chapters file.
    func startTimes(_ url: URL) throws -> [Double] {
        let file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let chapters = try #require(file["chapters"] as? [[String: Any]])
        return chapters.compactMap { $0["startTime"] as? Double }
    }

    /// C9.
    @Test func writesTheChaptersOfTheRange() async throws {
        let range = out("range.json")
        #expect(
            try await package.run("chapters", "export", "PKG", "--out", range.path, "--from", "480000")
                == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try startTimes(range) == [0, 2])
        let whole = out("whole.json")
        #expect(
            try await package.run("chapters", "export", "PKG", "--out", whole.path)
                == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try startTimes(whole) == [10, 12])
    }

    /// C10. Control: a write with no exists check replaces the old file.
    @Test func refusesAnExistingFile() async throws {
        let file = out("old.json")
        let old = Data("old bytes".utf8)
        try old.write(to: file)
        #expect(
            try await package.run("chapters", "export", "PKG", "--out", file.path)
                == CLIResult(status: 2, stdout: "", stderr: "Error: \(file.path) exists.\n"))
        #expect(try Data(contentsOf: file) == old, "the old bytes stay")
        #expect(
            try await package.run("chapters", "export", "PKG", "--out", file.path, "--replace")
                == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try startTimes(file) == [10, 12])
    }

    /// C10. A dangling link at --out is an item: the command does not replace it.
    @Test func refusesADanglingLink() async throws {
        let link = out("link.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: out("none.json").path)
        #expect(try await package.run("chapters", "export", "PKG", "--out", link.path).status == 2)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == out("none.json").path)
    }

    /// C11.
    @Test func noChapterExitsOne() async throws {
        let file = out("none.json")
        #expect(
            try await package.run("chapters", "export", "PKG", "--out", file.path, "--to", "480000")
                == CLIResult(status: 1, stdout: "", stderr: "Error: no chapter in frames 0..<480000.\n"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// Code gate item 1. A chapter at or after the session end is past the audio: the file leaves
    /// it out, and stderr names it. With --to past it, it is in the range and in the file.
    @Test func chaptersPastTheEndGetAWarning() async throws {
        try package.edit { session in
            try session.setMarker(Marker(id: "c", name: "Credits", position: 960_000, kind: .chapter))
            try session.setMarker(Marker(id: "d", name: "Bonus", position: 1_000_000, kind: .chapter))
        }
        let file = out("past.json")
        #expect(
            try await package.run("chapters", "export", "PKG", "--out", file.path)
                == CLIResult(
                    status: 0, stdout: "",
                    stderr: """
                        Warning: chapter "Credits" at 960000 is at or after the session end 960000; the file leaves it out.
                        Warning: chapter "Bonus" at 1000000 is at or after the session end 960000; the file leaves it out.

                        """))
        #expect(try startTimes(file) == [10, 12])
        let wide = out("wide.json")
        #expect(
            try await package.run("chapters", "export", "PKG", "--out", wide.path, "--to", "1100000")
                == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try startTimes(wide) == [10, 12, 20, 20.833])
    }

    /// Code gate item 1. A session with chapters and no clip has no range: exit 1, not 64.
    @Test func aSessionWithNoAudioExitsOne() async throws {
        var session = Session(sampleRate: 48_000)
        try session.setMarker(Marker(id: "a", name: "Intro", position: 48_000, kind: .chapter))
        let empty = try TemporaryPackage(session)
        let file = empty.folder.appending(path: "none.json")
        #expect(
            try await empty.run("chapters", "export", "PKG", "--out", file.path)
                == CLIResult(
                    status: 1, stdout: "",
                    stderr: """
                        Warning: chapter "Intro" at 48000 is at or after the session end 0; the file leaves it out.
                        Error: the session has no audio, so it has no range. Give --to.

                        """))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// C12. Each refusal names its rule and makes no file. `export` accepts the same ranges.
    @Test(arguments: [
        (["--out", "x.txt"], "--out must end in .json."),
        (["--out", "x.json", "--from", "-1"], "The range must be 0 or more"),
        (["--out", "x.json", "--from", "480000", "--to", "480000"], "The range must be 0 or more"),
        // Code gate item 3: the bound of ExportSource, 2^40 frames, as `export`.
        (["--out", "x.json", "--to", "1099511627777"], "The range must be 0 or more"),
    ])
    func badArgumentsExit64(arguments: [String], reason: String) async throws {
        let result = try await package.run(
            ["chapters", "export", "PKG"] + arguments.map { $0.hasPrefix("x.") ? out($0).path : $0 })
        #expect(result.status == 64)
        #expect(result.stderr.contains(reason))
        #expect(!FileManager.default.fileExists(atPath: out(arguments[1]).path))
    }
}
