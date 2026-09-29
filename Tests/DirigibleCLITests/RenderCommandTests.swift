import AVFoundation
import DirigibleCore
import Foundation
import Testing

/// `dirigible render` and the media state in `info` (timeline-playback criterion 18, decisions
/// 0011 and 0016). The package has a float WAV with a known ramp, so the mix is known exactly.
struct RenderCommandTests {
    let package: TemporaryPackage
    var out: URL { package.folder.appending(path: "mix.caf") }
    /// Frame `i` of `f1.wav`.
    static func sample(_ i: Int) -> Float { Float(i % 1000) / 1000 - 0.5 }

    /// Track `t1` (mono) with clip `c1`: frames 0..<20 000 of `f1.wav` at timeline 1000. Track
    /// `t2` (mono) with clip `c2` of `gone.wav`, which is not on the disk.
    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 20_000))
        try session.addFile(AudioFile(id: "gone", path: "gone.wav", layout: .mono, length: 20_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 1000, offset: 0, length: 20_000), on: "t1")
        package = try TemporaryPackage(session)
        try Self.writeWAV(package.url.appending(path: "Clips/f1.wav"), frames: 20_000)
    }

    /// A 32-bit float WAV, so the read gives the samples back exactly.
    static func writeWAV(_ url: URL, frames: Int) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buffer.floatChannelData![0][i] = sample(i) }
        try file.write(from: buffer)
    }

    func addMissingTrack() throws {
        try package.edit { session in
            try session.addTrack("t2", name: "Guest", layout: .mono)
            try session.place(Clip(id: "c2", file: "gone", start: 0, offset: 0, length: 20_000), on: "t2")
        }
    }

    func temporaryFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: package.folder.path).filter { $0.hasSuffix(".tmp") }
    }

    @Test func renderWritesTheMix() async throws {
        let result = try await package.run("render", "PKG", "--out", out.path, "--from", "0", "--to", "9600")

        #expect(result == CLIResult(status: 0, stdout: "", stderr: ""))
        let file = try AVAudioFile(forReading: out)
        #expect(file.fileFormat.sampleRate == 48_000 && file.fileFormat.channelCount == 2)
        #expect(file.fileFormat.commonFormat == .pcmFormatFloat32 && file.length == 9600)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 9600))
        try file.read(into: buffer)
        let expected = (0..<9600).map { $0 < 1000 ? 0 : Self.sample($0 - 1000) }
        for channel in 0..<2 {
            let samples = UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: 9600)
            #expect(zip(samples, expected).allSatisfy { abs($0 - $1) <= 1e-6 }, "channel \(channel)")
        }
        #expect(try temporaryFiles() == [])
    }

    /// Control: `renderWritesTheMix` has an empty stderr.
    @Test func renderWarnsForMissingMedia() async throws {
        try addMissingTrack()

        let result = try await package.run("render", "PKG", "--out", out.path)

        #expect(result.status == 0 && result.stdout == "")
        #expect(result.stderr == "Warning: file gone \"gone.wav\" is missing; its clips render as silence.\n")
        #expect(try AVAudioFile(forReading: out).length == 21_000)
    }

    @Test func renderRefusesAnOutputThatExists() async throws {
        let bytes = Data("keep".utf8)
        try bytes.write(to: out)

        let result = try await package.run("render", "PKG", "--out", out.path)

        #expect(result == CLIResult(status: 2, stdout: "", stderr: "Error: \(out.path) exists.\n"))
        #expect(try Data(contentsOf: out) == bytes)
        #expect(try temporaryFiles() == [])
    }

    /// Starts `dirigible` with `arguments` and returns its process ID. The child inherits no
    /// descriptor of the test process, and SIGINT has its default action and is not blocked, also
    /// when the test runner ignores or blocks it.
    func spawn(_ arguments: String...) throws -> pid_t {
        let binary = Bundle(for: TemporaryPackage.self).bundleURL.deletingLastPathComponent().appending(
            path: "dirigible")
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
        var argv: [UnsafeMutablePointer<CChar>?] = ([binary.path] + arguments).map { strdup($0) } + [nil]
        defer { for argument in argv { free(argument) } }
        var pid = pid_t()
        try #require(posix_spawn(&pid, binary.path, nil, &attributes, &argv, environ) == 0)
        return pid
    }

    /// A render that died leaves `.<name>.<UUID>.tmp`. The next render to the same output removes
    /// it. Control: a file of another output and a name with no UUID stay. Found by the code gate.
    @Test func renderRemovesTheLeftoversOfItsOutput() async throws {
        let leftover = ".mix.caf.\(UUID().uuidString).tmp"
        let kept = [".mix.caf.notes.tmp", ".other.caf.\(UUID().uuidString).tmp"]
        for name in [leftover] + kept {
            try Data("old".utf8).write(to: package.folder.appending(path: name))
        }

        let result = try await package.run("render", "PKG", "--out", out.path, "--to", "9600")

        #expect(result.status == 0)
        #expect(try temporaryFiles().sorted() == kept.sorted())
    }

    /// Control-C during a render removes its temporary file and leaves no output. Found by the
    /// code gate.
    @Test func anInterruptedRenderLeavesNoTemporaryFile() async throws {
        let pid = try spawn("render", package.path, "--out", out.path, "--to", "\(48_000 * 3600)")
        var status: Int32 = 0
        defer {
            if waitpid(pid, &status, WNOHANG) == 0 {
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
            }
        }
        let end = ContinuousClock.now + .seconds(20)
        while try temporaryFiles().isEmpty, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        try #require(try !temporaryFiles().isEmpty, "the render wrote no temporary file in 20 s")

        kill(pid, SIGINT)
        let stop = ContinuousClock.now + .seconds(20)
        while waitpid(pid, &status, WNOHANG) == 0, ContinuousClock.now < stop {
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(try temporaryFiles() == [])
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    /// 40 audio files, one clip each, and a limit of `limit` descriptors: the render cannot keep
    /// its 32 files open. It fails with a clear error and leaves no output, not a mix with silence
    /// where the audio is. Control: the same render with the default limit works. Found by the
    /// code gate.
    @Test(arguments: [20, 256])
    func aRenderWithNoFreeDescriptorFails(limit: Int) async throws {
        try package.edit { session in
            for k in 0..<40 {
                try session.addFile(AudioFile(id: FileID("m\(k)"), path: "m\(k).wav", layout: .mono, length: 100))
                try session.addTrack(TrackID("m\(k)"), name: "M\(k)", layout: .mono)
                try session.place(
                    Clip(id: ClipID("m\(k)"), file: FileID("m\(k)"), start: Frames(100 * k), offset: 0, length: 100),
                    on: TrackID("m\(k)"))
            }
        }
        for k in 0..<40 { try Self.writeWAV(package.url.appending(path: "Clips/m\(k).wav"), frames: 100) }
        let binary = Bundle(for: TemporaryPackage.self).bundleURL.deletingLastPathComponent().appending(
            path: "dirigible")

        let result = try await dirigible(
            shell: "ulimit -n \(limit) && exec \"$0\" \"$@\"", binary.path, "render", package.path, "--out", out.path)

        if limit == 20 {
            #expect(result.status == 2 && result.stdout == "")
            #expect(result.stderr == "Error: cannot open the audio files: Too many open files.\n")
            #expect(!FileManager.default.fileExists(atPath: out.path))
        } else {
            #expect(result == CLIResult(status: 0, stdout: "", stderr: ""))
        }
        #expect(try temporaryFiles() == [])
    }

    /// 10 min of stereo at 48 kHz: one buffer for the range would be 230 MB. `wait4` gives the
    /// maximum resident size of the child alone, so the parallel tests do not count. The child
    /// inherits no descriptor of the test process.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aLongRenderKeepsMemoryBounded() async throws {
        let pid = try spawn("render", package.path, "--out", out.path, "--to", "\(48_000 * 600)")

        var status: Int32 = 0
        var usage = rusage()
        let end = ContinuousClock.now + .seconds(120)
        while wait4(pid, &status, WNOHANG, &usage) == 0 {
            guard ContinuousClock.now < end else {
                kill(pid, SIGKILL)
                _ = wait4(pid, &status, 0, &usage)
                Issue.record("The render ran for more than 120 s")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(status == 0)
        #expect(usage.ru_maxrss < 64 << 20, "the maximum resident size is \(usage.ru_maxrss) bytes")
        #expect(try AVAudioFile(forReading: out).length == 48_000 * 600)
    }

    /// Text and JSON. A whole file shows no media state in the text.
    @Test func infoMarksMissingMedia() async throws {
        try addMissingTrack()
        try package.edit { session in
            try session.addFile(AudioFile(id: "short", path: "short.wav", layout: .mono, length: 20_000))
        }
        try Self.writeWAV(package.url.appending(path: "Clips/short.wav"), frames: 5000)

        let text = try await package.run("info", "PKG").stdout
        let json = try await package.run("info", "PKG", "--json").stdout

        #expect(text.contains("file f1 \"f1.wav\" mono length 20000\n"))
        #expect(text.contains("file gone \"gone.wav\" mono length 20000 media missing\n"))
        #expect(text.contains("file short \"short.wav\" mono length 20000 media short 5000\n"))
        let files = try #require(
            (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["files"] as? [[String: Any]])
        #expect(files.map { $0["media"] as? String } == ["ok", "missing", "short"])
        #expect(files.map { $0["mediaLength"] as? Int } == [nil, nil, 5000])
    }
}
