import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `dirigible import-session` (decision 0075). The target is the package of `ImportCommandTests`
/// (track `T`, "Host"); each source is a package beside it.
struct ImportSessionCommandTests {
    /// A source package `<name>.dirigible` beside `target` with a `.lock`, track "Host", and one
    /// clip of `Clips/a.wav` (1 s at `rate`). With no `wav`, the WAV is not written.
    static func source(
        beside target: TemporaryPackage, name: String = "Guest", rate: Int = 48_000, wav: Bool = true,
        clip: Bool = true
    ) throws -> URL {
        var session = Session(sampleRate: rate)
        try session.addFile(AudioFile(id: "a", path: "a.wav", layout: .mono, length: Frames(rate)))
        try session.addTrack("h", name: "Host", layout: .mono)
        if clip { try session.place(Clip(id: "A", file: "a", start: 0, offset: 0, length: Frames(rate)), on: "h") }
        let url = target.folder.appending(path: "\(name).dirigible")
        try FileManager.default.createDirectory(at: url.appending(path: "Clips"), withIntermediateDirectories: true)
        if wav {
            let samples = (0..<rate).map { Float(0.25 * sin(2 * Double.pi * 1000 * Double($0) / Double(rate))) }
            try ImportCommandTests.write(url.appending(path: "Clips/a.wav"), .wav(.bits24), rate: rate, samples)
        }
        try session.write(to: url)
        FileManager.default.createFile(atPath: url.appending(path: ".lock").path, contents: nil)
        return url
    }

    /// C9: the command prints the new track IDs, and the session has the new track and its clip.
    @Test func importSessionPrintsTheNewTracks() async throws {
        let package = try ImportCommandTests.package()
        let source = try Self.source(beside: package)

        let run = try await package.run("import-session", "PKG", source.path)

        let session = try package.read()
        #expect(run.status == 0 && run.stderr.isEmpty, "\(run)")
        #expect(run.stdout == session.tracks.dropFirst().map { "\($0.id)\n" }.joined())
        #expect(session.tracks.map(\.name) == ["Host", "Host (Guest)"])
        #expect(session.tracks.last.map { Array($0.clips).map(\.length) } == [48_000])
        #expect(try await package.run("--help").stdout.contains("import-session"))
    }

    /// C9: each refusal exits with its code and its line, and `session.xml` does not change.
    @Test func eachRefusalHasItsExitCodeAndLine() async throws {
        let big = 1 << 40
        let cases: [(name: String, args: (TemporaryPackage, URL) throws -> [String], status: Int32, line: String)] = [
            (
                "at over", { [$1.path, "--at", "\(big + 1)"] }, 64,
                "the offset \(big + 1) is outside -2^40...2^40 frames. Give an offset in -\(big)...\(big)."
            ),
            (
                "at under", { [$1.path, "--at=-\(big + 1)"] }, 64,
                "the offset -\(big + 1) is outside -2^40...2^40 frames. Give an offset in -\(big)...\(big)."
            ),
            ("at limit", { [$1.path, "--at", "\(big)"] }, 1, "a frame is negative or more than 2^40."),
            (
                "same", { package, _ in [package.path] }, 1,
                "PKG is the same session as PKG, so Dirigible does not import it. Give a different source."
            ),
            (
                "no clip after at", { [$1.path, "--at=-48000"] }, 1,
                "SRC has no clip to import. Give a session with a clip, or an --at value that keeps one."
            ),
        ]
        for item in cases {
            let package = try ImportCommandTests.package()
            let source = try Self.source(beside: package)
            let before = try package.xml()
            let run = try await package.run(["import-session", "PKG"] + item.args(package, source))
            let line = item.line.replacing("PKG", with: package.path).replacing("SRC", with: source.path)
            #expect(run.status == item.status && errorText(run) == line, "\(item.name): \(run)")
            #expect(try package.xml() == before, "\(item.name) changed session.xml")
        }
    }

    /// C9: a source fault exits 2 with a line that names the source path as given.
    @Test func aSourceFaultExitsTwoAndNamesTheSource() async throws {
        let cases: [(name: String, make: (TemporaryPackage) throws -> URL, line: String)] = [
            (
                "rate", { try Self.source(beside: $0, rate: 7_999, wav: false) },
                "the sample rate 7999 Hz is outside 8000...384000 Hz, so Dirigible does not import SRC."
            ),
            (
                "link",
                { package in
                    let source = try Self.source(beside: package)
                    let a = source.appending(path: "Clips/a.wav")
                    let outside = package.folder.appending(path: "outside.wav")
                    try FileManager.default.moveItem(at: a, to: outside)
                    try FileManager.default.createSymbolicLink(at: a, withDestinationURL: outside)
                    return source
                },
                "SRC/Clips/a.wav is a link, a folder, or a path through a link, so Dirigible does not import SRC. "
                    + "Replace that item with a plain file."
            ),
            (
                "fifo",
                { package in
                    let source = try Self.source(beside: package)
                    let a = source.appending(path: "Clips/a.wav")
                    unlink(a.path)
                    try #require(mkfifo(a.path, 0o644) == 0)
                    return source
                },
                "SRC/Clips/a.wav is a link, a special file, or an item of the wrong kind, so Dirigible does not "
                    + "open the package. Replace that item with a plain file or folder, or remove it."
            ),
            (
                "xml",
                { package in
                    let source = try Self.source(beside: package)
                    let xml = source.appending(path: "session.xml")
                    try String(contentsOf: xml, encoding: .utf8)
                        .replacing("?>", with: "?>\n<!DOCTYPE session []>", maxReplacements: 1)
                        .write(to: xml, atomically: true, encoding: .utf8)
                    return source
                },
                "SRC/session.xml is not a Dirigible session file."
            ),
            (
                "take",
                { package in
                    let source = try Self.source(beside: package)
                    var session = try Session(contentsOf: source)
                    try session.setRecording(
                        Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 0, armedTracks: []))
                    try session.write(to: source)
                    return source
                },
                "SRC has a take that is not finalized; open it in Dirigible first."
            ),
        ]
        for item in cases {
            let package = try ImportCommandTests.package()
            let source = try item.make(package)
            let before = try package.xml()
            let run = try await package.run("import-session", "PKG", source.path)
            #expect(
                run.status == 2 && errorText(run) == item.line.replacing("SRC", with: source.path),
                "\(item.name): \(run)")
            #expect(try package.xml() == before, "\(item.name) changed session.xml")
        }
        let closed = try ImportCommandTests.package()
        let source = try Self.source(beside: closed)
        let capture = source.appending(path: "Capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        chmod(capture.path, 0o000)
        defer { chmod(capture.path, 0o755) }
        let run = try await closed.run("import-session", "PKG", source.path)
        #expect(run.status == 2 && errorText(run) == "cannot read \(source.path)/Capture: Permission denied.", "\(run)")
    }

    /// C9: a target at a rate out of the range exits 2 with a line that names the target.
    @Test func aTargetRateOutsideTheRangeExitsTwo() async throws {
        let package = try TemporaryPackage(Session(sampleRate: 7_999))
        let source = try Self.source(beside: package)

        let run = try await package.run("import-session", "PKG", source.path)

        #expect(run.status == 2, "\(run)")
        #expect(
            errorText(run)
                == "the sample rate 7999 Hz of \(package.path) is outside 8000...384000 Hz, so Dirigible does not "
                + "import a session into it.")
    }
}
