import AVFoundation
import DirigibleCore
import Foundation
import Testing

/// `dirigible clip denoise` (decision 0054, criteria C11 and C13). Track `t1` "Host" (no role) holds
/// `c1` and `c2` of the 4 s mono file `f1`; track `t2` "Bed" (music) holds `m1` of the 1 s file `m1`.
struct DenoiseCommandTests {
    static func package(seconds: Double = 4, bedRole: Track.Role = .music) throws -> TemporaryPackage {
        let frames = Frames(Int(seconds * 48_000))
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: frames))
        try session.addFile(AudioFile(id: "m1", path: "m1.wav", layout: .mono, length: 48_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Bed", layout: .mono)
        try session.setRole(bedRole, tracks: ["t2"])
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 48_000), on: "t1")
        try session.place(Clip(id: "c2", file: "f1", start: 96_000, offset: 96_000, length: 48_000), on: "t1")
        try session.place(Clip(id: "m1", file: "m1", start: 0, offset: 0, length: 48_000), on: "t2")
        let package = try TemporaryPackage(session)
        let clips = package.url.appending(path: "Clips")
        try LoudnessCommandTests.writeWAV(clips.appending(path: "f1.wav"), seconds: seconds, channels: 1)
        try LoudnessCommandTests.writeWAV(clips.appending(path: "m1.wav"), seconds: 1, channels: 1)
        return package
    }

    /// The names in `Clips/`.
    static func clips(_ package: TemporaryPackage) -> [String] {
        let names = try? FileManager.default.contentsOfDirectory(atPath: package.url.appending(path: "Clips").path)
        return (names ?? []).sorted()
    }

    /// C11: one line `<clip>\t<new file>` for each clip, the session is saved with the clips on the
    /// new file, the new WAV has the frames of the file record, and the other clips stay.
    @Test func denoisesAndPrints() async throws {
        let package = try Self.package()

        let result = try await package.run("clip", "denoise", "PKG", "c1", "c2", "--reduction", "30")

        let session = try package.read()
        let moved = try ["c1", "c2"].map { try #require(session.clip(ClipID($0))?.clip.file) }
        #expect(moved.allSatisfy { $0 != "f1" }, "the clips stay on f1: \(moved)")
        let lines = zip(["c1", "c2"], moved).map { "\($0)\t\($1)" }
        #expect(
            result == CLIResult(status: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: ""),
            "denoise: \(result)")
        #expect(session.clip("m1")?.clip.file == "m1", "a clip that was not named moved")
        let file = try #require(session.files[moved[0]])
        #expect(Self.clips(package).contains(file.path), "\(Self.clips(package)) has no \(file.path)")
        let wav = try AVAudioFile(forReading: package.url.appending(path: "Clips/\(file.path)"))
        #expect(wav.length == file.length.count && file.layout == .mono, "\(wav.length) frames, \(file)")
    }

    /// C5: the amount of the level again prints "Nothing to change.", exits 0, and writes no file
    /// and no `session.xml`.
    @Test func equalAmountPrintsNothingToChange() async throws {
        let package = try Self.package()
        let first = try await package.run("clip", "denoise", "PKG", "c1", "--reduction", "12")
        try #require(first.status == 0, "\(first)")
        let before = (try package.xml(), Self.clips(package))

        let result = try await package.run("clip", "denoise", "PKG", "c1", "--reduction", "12")

        #expect(result == CLIResult(status: 0, stdout: "Nothing to change.\n", stderr: ""), "\(result)")
        #expect(try package.xml() == before.0 && Self.clips(package) == before.1)
    }

    /// C11: a reduction outside 1...30 and a value that is not a whole number exit 64 and change
    /// nothing.
    @Test(arguments: ["0", "31", "nan"])
    func badReductionExits64(value: String) async throws {
        let package = try Self.package()
        let before = (try package.xml(), Self.clips(package))

        let result = try await package.run("clip", "denoise", "PKG", "c1", "--reduction", value)

        #expect(result.status == 64 && result.stdout == "", "reduction \(value): \(result)")
        #expect(result.stderr.contains("an integer from 1 to 30"), "reduction \(value): \(result.stderr)")
        #expect(try package.xml() == before.0 && Self.clips(package) == before.1, "a refused call changed the package")
    }

    /// C11 and C10: an unknown clip exits 1 with the text of the session and changes nothing. A work
    /// error takes the same path.
    @Test func unknownClipExits1() async throws {
        let package = try Self.package()
        let before = (try package.xml(), Self.clips(package))

        let result = try await package.run("clip", "denoise", "PKG", "c1", "zz")

        #expect(result.status == 1 && result.stdout == "", "unknown clip: \(result)")
        #expect(result.stderr.hasPrefix("Error: ") && result.stderr.contains("zz"), "\(result.stderr)")
        #expect(try package.xml() == before.0 && Self.clips(package) == before.1, "a refused call changed the package")
    }

    /// C13: a clip on a music or effects track exits 1 with the text of the role refusal and writes nothing,
    /// also when a clip of a voice track comes with it. The help says so.
    @Test(arguments: [Track.Role.music, .effects]) func nonVoiceClipExits1(role: Track.Role) async throws {
        let package = try Self.package(bedRole: role)
        let before = (try package.xml(), Self.clips(package))

        let result = try await package.run("clip", "denoise", "PKG", "c1", "m1")

        let text =
            "the noise reduction refuses clip \"m1\": its track has the role \(role.rawValue), "
            + "and the noise reduction keeps only voices."
        #expect(result == CLIResult(status: 1, stdout: "", stderr: "Error: \(text)\n"), "music clip: \(result)")
        #expect(try package.xml() == before.0 && Self.clips(package) == before.1, "a refused call changed the package")
        let help = try await dirigible("clip", "denoise", "--help")
        let words = help.stdout.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(words.contains("music or effects track"), "the help does not name the role rule: \(help.stdout)")
    }

    /// C11: Control-C during the render leaves no new file, no temporary file, and the same
    /// `session.xml`, and exits 130 with nothing on stdout.
    @Test func interruptWritesNothing() async throws {
        let package = try Self.package(seconds: 120)
        let before = (try package.xml(), Self.clips(package))
        let pid = try spawnDirigible("clip", "denoise", package.path, "c1")
        var status: Int32 = 0
        defer {
            if waitpid(pid, &status, WNOHANG) == 0 {
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
            }
        }
        let end = ContinuousClock.now + .seconds(20)
        while Self.clips(package) == before.1, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        try #require(Self.clips(package) != before.1, "the render wrote no temporary file in 20 s")

        kill(pid, SIGINT)
        let stop = ContinuousClock.now + .seconds(20)
        var finished = waitpid(pid, &status, WNOHANG)
        while finished == 0, ContinuousClock.now < stop {
            try await Task.sleep(for: .milliseconds(1))
            finished = waitpid(pid, &status, WNOHANG)
        }

        try #require(finished == pid, "the command did not end in 20 s")
        #expect(status >> 8 == 128 + SIGINT && status & 0x7f == 0, "wait status \(status)")
        #expect(Self.clips(package) == before.1, "\(Self.clips(package))")
        #expect(try package.xml() == before.0, "an interrupted render changed session.xml")
    }
}

/// Starts `dirigible` with `arguments` and returns its process ID. The child inherits no
/// descriptor of the test process, and SIGINT has its default action and is not blocked, also when
/// the test runner ignores or blocks it. Its output goes to /dev/null.
func spawnDirigible(_ arguments: String...) throws -> pid_t {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(
        &attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
    var signals = sigset_t()
    sigemptyset(&signals)
    posix_spawnattr_setsigmask(&attributes, &signals)
    sigaddset(&signals, SIGINT)
    posix_spawnattr_setsigdefault(&attributes, &signals)
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
        posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_WRONLY, 0)
    }
    var argv: [UnsafeMutablePointer<CChar>?] = ([dirigibleBinary.path] + arguments).map { strdup($0) } + [nil]
    defer { for argument in argv { free(argument) } }
    var pid = pid_t()
    try #require(posix_spawn(&pid, dirigibleBinary.path, &actions, &attributes, &argv, environ) == 0)
    return pid
}
