import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleMCP

/// `dirigible transcribe` (decision 0065, C16, C19). The model folder is `DIRIGIBLE_MODELS_FOLDER`.
struct TranscribeCommandTests {
    /// A package with track t1 and one clip of a 10 s sine on it.
    static func package() throws -> TemporaryPackage {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "tone", path: "tone.wav", layout: .mono, length: 480_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.place(Clip(id: "tone", file: "tone", start: 0, offset: 0, length: 480_000), on: "t1")
        let package = try TemporaryPackage(session)
        try LoudnessCommandTests.writeWAV(
            package.url.appending(path: "Clips/tone.wav"), seconds: 10, channels: 1)
        return package
    }

    /// Runs `dirigible transcribe PKG <arguments>` with `models` as the model folder. Each argument
    /// is one shell word with no quote. A case that runs the engine gives `limit` of 120 s: the debug
    /// engine took 18 s of the 30 s default at load 3.
    static func transcribe(
        _ package: TemporaryPackage, models: URL, limit: Duration = .seconds(30), _ arguments: String...
    ) async throws -> CLIResult {
        try await dirigible(
            shell: "DIRIGIBLE_MODELS_FOLDER=\"$1\" exec \"$0\" transcribe \"$2\" " + arguments.joined(separator: " "),
            dirigibleBinary.path, models.path, package.path, limit: limit)
    }

    static func transcripts(_ package: TemporaryPackage) -> Bool {
        FileManager.default.fileExists(atPath: package.url.appending(path: "Transcripts").path)
    }

    @Test func aMissingModelExitsOne() async throws {
        let package = try Self.package()
        let models = package.folder.appending(path: "Models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let result = try await Self.transcribe(package, models: models, "--track", "t1")
        let expected = "Error: no whisper model at \(models.appending(path: "ggml-base.bin").path)\n"
        #expect(result == CLIResult(status: 1, stdout: "", stderr: expected), "\(result)")
        #expect(!Self.transcripts(package), "a failed transcribe wrote a Transcripts folder")

        let turbo = try await Self.transcribe(
            package, models: models, "--track", "t1", "--model", "large-v3-turbo-q5_0")
        let turboFile = models.appending(path: "ggml-large-v3-turbo-q5_0.bin").path
        #expect(
            turbo == CLIResult(status: 1, stdout: "", stderr: "Error: no whisper model at \(turboFile)\n"), "\(turbo)")
    }

    @Test func aBadLanguageExits64() async throws {
        let package = try Self.package()
        let result = try await Self.transcribe(
            package, models: package.folder, "--track", "t1", "--language", "klingon")
        #expect(result.status == 64, "\(result)")
        #expect(result.stderr.hasPrefix("Error: unknown language klingon"), "\(result)")
    }

    @Test func anUnknownModelNameExits64() async throws {
        let package = try Self.package()
        let result = try await Self.transcribe(package, models: package.folder, "--track", "t1", "--model", "huge")
        #expect(result.status == 64, "\(result)")
        #expect(result.stderr.hasPrefix("Error: unknown model huge\n"), "\(result)")
    }

    /// The check of the byte count fails before the hash: the file has 1 byte.
    @Test func aModelOfTheWrongSizeExitsOne() async throws {
        let package = try Self.package()
        let model = package.folder.appending(path: "ggml-base.bin")
        FileManager.default.createFile(atPath: model.path, contents: Data([1]))
        let result = try await Self.transcribe(package, models: package.folder, "--track", "t1")
        let expected = "Error: the whisper model at \(model.path) does not match its checksum\n"
        #expect(result == CLIResult(status: 1, stdout: "", stderr: expected), "\(result)")
        #expect(!Self.transcripts(package), "a failed transcribe wrote a Transcripts folder")
    }

    @Test func anUnknownTrackExitsOne() async throws {
        let package = try Self.package()
        FileManager.default.createFile(
            atPath: package.folder.appending(path: "ggml-base.bin").path, contents: Data([1]))
        let before = try package.xml()
        let result = try await Self.transcribe(package, models: package.folder, "--track", "t9")
        #expect(result.status == 1 && result.stdout.isEmpty, "\(result)")
        #expect(result.stderr.hasPrefix("Error: ") && result.stderr.contains("t9"), "\(result)")
        #expect(try package.xml() == before)
    }

    /// Plan change after S3 item 3: with no ID, stdout holds only the `Imported` line, and the
    /// skip line goes to stderr.
    @Test func noIDPutsTheSkipLineOnStderr() {
        let lines = TranscribeWork.lines(id: nil, kept: 0, skipped: 0, untimed: 1, dropped: [])
        let output = TranscriptWork.importOutput(lines)
        #expect(output.stdout == ["Imported 0 words."])
        #expect(output.stderr == ["Skipped 1 word with no time."])
    }

    /// The folder of `scripts/fetch-whisper-test-model.sh`: the models and the VAD model.
    static var fetched: URL {
        let cache = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map { URL(filePath: $0) }
        return (cache ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache"))
            .appending(path: "dirigible/whisper")
    }

    /// A package with track t1 and one clip of `samples` at 48 kHz mono.
    static func package(samples: [Float]) throws -> TemporaryPackage {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "a", path: "a.wav", layout: .mono, length: Frames(samples.count)))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.place(Clip(id: "a", file: "a", start: 0, offset: 0, length: Frames(samples.count)), on: "t1")
        let package = try TemporaryPackage(session)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let clips = package.url.appending(path: "Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: clips.appending(path: "a.wav"), settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
        return package
    }

    /// 48 kHz mono speech of `say` with the system voice.
    static func speech(_ text: String) throws -> [Float] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "say-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "say.wav")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/say")
        process.arguments = ["--file-format=WAVE", "--data-format=LEF32@48000", "-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "say exit \(process.terminationStatus)")
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    /// Pink noise (the filter of Paul Kellet on seeded white noise) at `dBFS` RMS.
    static func pinkNoise(count: Int, dBFS: Double) -> [Float] {
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        var (b0, b1, b2) = (0.0, 0.0, 0.0)
        var noise = (0..<count).map { _ -> Double in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let white = Double(seed >> 11) / Double(1 << 53) * 2 - 1
            b0 = 0.99765 * b0 + white * 0.0990460
            b1 = 0.96300 * b1 + white * 0.2965164
            b2 = 0.57000 * b2 + white * 1.0526913
            return b0 + b1 + b2 + white * 0.1848
        }
        let rms = (noise.reduce(0) { $0 + $1 * $1 } / Double(count)).squareRoot()
        let scale = pow(10, dBFS / 20) / rms
        noise = noise.map { $0 * scale }
        return noise.map(Float.init)
    }

    /// The test model `tiny-q5_1` keeps the run of the debug engine under the 120 s limit of a child.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aSpeechTrackGivesItsWords() async throws {
        let package = try Self.package(samples: try Self.speech("The morning train left the station at seven."))
        let result = try await Self.transcribe(
            package, models: Self.fetched, limit: .seconds(120),
            "--track", "t1", "--language", "en", "--model", "tiny-q5_1")
        #expect(result.status == 0 && result.stderr.isEmpty, "\(result)")
        #expect(result.stdout.wholeMatch(of: #/1\nImported [1-9][0-9]* words?\.\n/#) != nil, "\(result)")
        let words = try package.read().words().map(\.text).joined(separator: " ").lowercased()
        #expect(words.contains("train") && words.contains("station"), "words: \(words)")
        let names = try FileManager.default.contentsOfDirectory(atPath: package.url.appending(path: "Transcripts").path)
        #expect(names.count == 1, "Transcripts: \(names)")
    }

    /// C16: 60 s of digital silence, then 30 s of pink noise at -40 dBFS, gives 0 words with VAD on,
    /// and the package does not change: the bytes and the modification date of session.xml.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aSilentTrackGivesZeroWords() async throws {
        let samples = [Float](repeating: 0, count: 60 * 48_000) + Self.pinkNoise(count: 30 * 48_000, dBFS: -40)
        let package = try Self.package(samples: samples)
        let before = try package.xml()
        let date = {
            try FileManager.default.attributesOfItem(atPath: package.sessionXML.path)[.modificationDate] as? Date
        }
        let dateBefore = try date()
        let result = try await Self.transcribe(package, models: Self.fetched, limit: .seconds(120), "--track", "t1")
        #expect(result == CLIResult(status: 0, stdout: "Imported 0 words.\n", stderr: ""), "\(result)")
        #expect(try package.xml() == before, "session.xml bytes changed")
        #expect(try date() == dateBefore, "session.xml was written again")
        #expect(!Self.transcripts(package), "0 words wrote a Transcripts folder")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aModelWithOneChangedByteExitsOne() async throws {
        let package = try Self.package()
        let model = package.folder.appending(path: "ggml-tiny-q5_1.bin")
        var data = try Data(contentsOf: Self.fetched.appending(path: "ggml-tiny-q5_1.bin"))
        data[data.count / 2] ^= 0xFF
        try data.write(to: model)
        let result = try await Self.transcribe(
            package, models: package.folder, "--track", "t1", "--model", "tiny-q5_1")
        let expected = "Error: the whisper model at \(model.path) does not match its checksum\n"
        #expect(result == CLIResult(status: 1, stdout: "", stderr: expected), "\(result)")
        #expect(!Self.transcripts(package), "a failed transcribe wrote a Transcripts folder")
    }
}
