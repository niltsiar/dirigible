import AVFoundation
import DirigibleCore
import Foundation
import Testing

/// `dirigible export --split` (decision 0067, criteria C9, C12, and C13). The package of
/// `ExportCommandTests` with the chapters Intro at frame 0, Interview at 8000, and Outro at 15 000,
/// so the stem `Ep` gives `Ep-01-Intro`, `Ep-02-Interview`, and `Ep-03-Outro`.
extension ExportCommandTests {
    static let partNames = ["Ep-01-Intro", "Ep-02-Interview", "Ep-03-Outro"]

    func addChapters() throws {
        try package.edit { session in
            try session.setMarker(Marker(id: "a", name: "Intro", position: 0, kind: .chapter))
            try session.setMarker(Marker(id: "b", name: "Interview", position: 8000, kind: .chapter))
            try session.setMarker(Marker(id: "c", name: "Outro", position: 15_000, kind: .chapter))
        }
    }

    /// The names in the folder of the package, sorted.
    func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: package.folder.path).sorted()
    }

    func paths(_ names: [String], _ pathExtension: String) -> [String] {
        names.map { out("\($0).\(pathExtension)").path }
    }

    @Test func splitChaptersWritesOneFileForEachChapter() async throws {
        try addChapters()

        let result = try await package.run("export", "PKG", "--out", out("Ep.mp3").path, "--split", "chapters")

        let lines = paths(Self.partNames, "mp3").map { $0 + "\n" }.joined()
        #expect(result == CLIResult(status: 0, stdout: lines, stderr: ""), "\(result)")
        #expect(try names() == Self.partNames.map { $0 + ".mp3" } + ["Show.dirigible"], "no stem file, no temp file")
        for name in Self.partNames {
            let file = try AVAudioFile(forReading: out(name + ".mp3"))
            #expect(file.length > 0, "\(name)")
        }
    }

    @Test func anExistingPartFileExitsTwoAndWritesNothing() async throws {
        try addChapters()
        let old = out("Ep-02-Interview.mp3")
        try Data("keep".utf8).write(to: old)

        let result = try await package.run("export", "PKG", "--out", out("Ep.mp3").path, "--split", "chapters")

        let text = "Error: 1 file exists: \(old.path). Use --replace to replace it.\n"
        #expect(result == CLIResult(status: 2, stdout: "", stderr: text), "\(result)")
        #expect(try names() == ["Ep-02-Interview.mp3", "Show.dirigible"])
        #expect(try Data(contentsOf: old) == Data("keep".utf8))
    }

    @Test func replaceTakesEachExistingFile() async throws {
        try addChapters()
        let old = [out("Ep-02-Interview.mp3"), out("Ep-03-Outro.mp3")]
        for file in old { try Data("old".utf8).write(to: file) }
        try Data("stem".utf8).write(to: out("Ep.mp3"))

        let refused = try await package.run("export", "PKG", "--out", out("Ep.mp3").path, "--split", "chapters")
        #expect(refused.status == 2 && refused.stderr.contains(old[0].path) && refused.stderr.contains(old[1].path))
        #expect(try names() == ["Ep-02-Interview.mp3", "Ep-03-Outro.mp3", "Ep.mp3", "Show.dirigible"])

        let result = try await package.run(
            "export", "PKG", "--out", out("Ep.mp3").path, "--split", "chapters", "--replace")

        #expect(result.status == 0 && result.stdout.split(separator: "\n").count == 3, "\(result)")
        for file in old { #expect(try AVAudioFile(forReading: file).length > 0, "\(file.lastPathComponent)") }
        #expect(try Data(contentsOf: out("Ep.mp3")) == Data("stem".utf8), "the stem file is never written")
        #expect(try temporaryFiles() == [])
    }

    /// C12: file `gone` is missing in part 3 only. The set stops before part 1 is on disk.
    @Test func aMissingFileInPartThreeRefusesBeforePartOne() async throws {
        try addChapters()
        try package.edit { session in
            try session.place(Clip(id: "c2", file: "gone", start: 15_000, offset: 0, length: 5000), on: "t2")
        }

        let result = try await package.run("export", "PKG", "--out", out("Ep.mp3").path, "--split", "chapters")

        #expect(result.status == 2 && result.stdout == "", "\(result)")
        #expect(result.stderr.hasPrefix("Error: file gone "), "\(result.stderr)")
        #expect(try names() == ["Show.dirigible"], "a part was written before the refusal")

        let allowed = try await package.run(
            "export", "PKG", "--out", out("Ep.mp3").path, "--split", "chapters", "--allow-missing")
        #expect(allowed.status == 0 && allowed.stderr.hasPrefix("Warning: file gone "), "\(allowed)")
    }

    /// A plain marker is no chapter. Control: `markers` on a package with no marker.
    @Test(arguments: [("chapters", true), ("markers", false)])
    func aRangeWithNoChapterExitsOne(word: String, hasPlainMarker: Bool) async throws {
        if hasPlainMarker {
            try package.edit { try $0.setMarker(Marker(id: "m", name: "Note", position: 8000, kind: .marker)) }
        }

        let result = try await package.run("export", "PKG", "--out", out("Ep.mp3").path, "--split", word)

        let noun = word == "chapters" ? "chapter" : "marker"
        let text = "Error: no \(noun) in frames 0..<21000.\n"
        #expect(result == CLIResult(status: 1, stdout: "", stderr: text), "\(result)")
        #expect(try names() == ["Show.dirigible"])
    }

    @Test func anUnknownSplitWordExitsSixtyFour() async throws {
        try addChapters()

        let result = try await package.run("export", "PKG", "--out", out("Ep.mp3").path, "--split", "sections")

        #expect(result.status == 64 && result.stderr.contains("--split must be chapters or markers."), "\(result)")
        #expect(try names() == ["Show.dirigible"])
    }

    /// C13: each line has the loudness line of its file. Chapters at 5 s and 12 s of 20 s at -30 dBFS.
    @Test func withLoudnessEachLineHasTheLoudnessOfItsFile() async throws {
        let package = try ExportLoudnessCommandTests.package(dBFS: -30)
        try package.edit { session in
            try session.setMarker(Marker(id: "a", name: "One", position: 0, kind: .chapter))
            try session.setMarker(Marker(id: "b", name: "Two", position: 240_000, kind: .chapter))
            try session.setMarker(Marker(id: "c", name: "Three", position: 576_000, kind: .chapter))
        }
        let stem = package.folder.appending(path: "Ep.wav")

        let result = try await package.run(
            "export", "PKG", "--out", stem.path, "--split", "chapters", "--loudness", "podcast")

        #expect(result.status == 0 && result.stderr == "", "\(result)")
        let lines = result.stdout.split(separator: "\n").map(String.init)
        try #require(lines.count == 3, "\(result)")
        for (line, name) in zip(lines, ["Ep-01-One", "Ep-02-Two", "Ep-03-Three"]) {
            let file = package.folder.appending(path: name + ".wav")
            let parts = line.split(separator: "\t").map(String.init)
            try #require(parts.count == 2 && parts[0] == file.path, "\(line)")
            #expect(parts[1].hasPrefix("loudness -16.0 LUFS"), "\(line)")
            let back = try ExportLoudnessCommandTests.loudness(file)?.value ?? .nan
            #expect(abs(back - -16) <= 0.1, "\(name): \(back) LUFS")
        }
    }

    /// C13, H1: Control-C during part 3 of 5. Parts 1 and 2 stay and print; the stop line names
    /// the three parts not written; exit 130. Parts 1 and 2 are 1 s; part 3 is 240 s of MP3.
    @Test func controlCDuringPartThreePrintsTheWrittenFilesAndTheStopLine() async throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 11_760_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 11_760_000), on: "t1")
        for (index, second) in [0, 1, 2, 242, 243].enumerated() {
            try session.setMarker(
                Marker(
                    id: MarkerID("m\(index)"), name: "Part\(index + 1)", position: Frames(second * 48_000),
                    kind: .chapter))
        }
        session.setEpisode(try Self.titledEpisode())
        let package = try TemporaryPackage(session)
        try LoudnessCommandTests.writeWAV(
            package.url.appending(path: "Clips/f1.wav"), seconds: 245, channels: 1, dBFS: -30)
        let logs = FileManager.default.temporaryDirectory.appending(path: "dirigible-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logs) }
        let (stdout, stderr) = (logs.appending(path: "stdout"), logs.appending(path: "stderr"))
        let stem = package.folder.appending(path: "Ep.mp3")
        let pid = try spawnDirigible(
            "export", package.path, "--out", stem.path, "--split", "chapters", output: (stdout, stderr))
        var status: Int32 = 0
        defer {
            if waitpid(pid, &status, WNOHANG) == 0 {
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
            }
        }
        func inPartThree() -> Bool {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: package.folder.path)) ?? []
            return items.contains { $0.hasPrefix(".Ep-03") } && items.contains { $0.hasPrefix("Ep-02-") }
        }
        let end = ContinuousClock.now + .seconds(60)
        while !inPartThree(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        try #require(inPartThree(), "part 3 did not start in 60 s")

        kill(pid, SIGINT)
        let stop = ContinuousClock.now + .seconds(30)
        var finished = waitpid(pid, &status, WNOHANG)
        while finished == 0, ContinuousClock.now < stop {
            try await Task.sleep(for: .milliseconds(1))
            finished = waitpid(pid, &status, WNOHANG)
        }

        try #require(finished == pid, "the command did not end in 30 s")
        #expect(status >> 8 == 128 + SIGINT && status & 0x7f == 0, "wait status \(status)")
        func path(_ name: String) -> String { package.folder.appending(path: name).path }
        let written = ["Ep-01-Part1.mp3", "Ep-02-Part2.mp3"].map { path($0) + "\n" }.joined()
        #expect(try String(contentsOf: stdout, encoding: .utf8) == written)
        let remaining = ["Ep-03-Part3.mp3", "Ep-04-Part4.mp3", "Ep-05-Part5.mp3"].map { path($0) }.joined(
            separator: ", ")
        let line = "Stopped: 3 files were not written: \(remaining). An existing file at each path did not change.\n"
        #expect(try String(contentsOf: stderr, encoding: .utf8) == line)
        let left = try FileManager.default.contentsOfDirectory(atPath: package.folder.path).sorted()
        #expect(left == ["Ep-01-Part1.mp3", "Ep-02-Part2.mp3", "Show.dirigible"], "\(left)")
    }

    /// C7: an episode with no title and a set whose parts all have titles prints no title warning.
    @Test func aPartWithATitleHasNoTitleWarning() async throws {
        try addChapters()
        try package.edit { $0.setEpisode(Episode()) }

        let result = try await package.run("export", "PKG", "--out", out("Ep.mp3").path, "--split", "chapters")

        #expect(result.status == 0 && result.stderr == "", "\(result)")
    }

    /// Lead ruling 1b row 6: the older files of the stem get one stderr line, also with no target before.
    @Test func oldFilesOfTheStemGetOneStderrLine() async throws {
        try addChapters()
        let outro = out("Ep-05-Outro.mp3")
        try Data("old".utf8).write(to: outro)

        let one = try await package.run("export", "PKG", "--out", out("Ep.mp3").path, "--split", "chapters")

        let line = "Warning: 1 older file of this stem stays: \(outro.path). Dirigible does not delete it.\n"
        #expect(one.status == 0 && one.stderr == line, "\(one)")
        #expect(try Data(contentsOf: outro) == Data("old".utf8))

        let tail = out("Ep-04-Tail.mp3")
        try Data("old".utf8).write(to: tail)
        let two = try await package.run(
            "export", "PKG", "--out", out("Ep.mp3").path, "--split", "chapters", "--replace")
        let both =
            "Warning: 2 older files of this stem stay: \(tail.path), \(outro.path). Dirigible does not delete them.\n"
        #expect(two.status == 0 && two.stderr == both, "\(two)")
    }

    /// With no `--split`, a package with chapters writes the one file.
    @Test func noSplitKeepsTheOutputOfToday() async throws {
        try addChapters()

        let result = try await package.run("export", "PKG", "--out", out("Ep.mp3").path)

        #expect(result == CLIResult(status: 0, stdout: "", stderr: ""), "\(result)")
        #expect(try names() == ["Ep.mp3", "Show.dirigible"])
    }
}
