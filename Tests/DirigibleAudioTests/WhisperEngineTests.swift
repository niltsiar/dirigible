import CWhisper
import Foundation
import Testing

@testable import DirigibleAudio

/// The model files of `scripts/fetch-whisper-test-model.sh`. A slow test with no fixture fails.
enum WhisperFixture {
    static var folder: URL {
        let environment = ProcessInfo.processInfo.environment
        let cache =
            environment["XDG_CACHE_HOME"].map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache")
        return cache.appending(path: "dirigible/whisper")
    }

    static var vad: URL { folder.appending(path: "ggml-silero-v6.2.0.bin") }

    static func model(_ model: WhisperModel) throws -> CheckedModel {
        try #require(
            model.checked(in: folder), "no checked \(model.fileName): run scripts/fetch-whisper-test-model.sh")
    }

    /// Pink noise (the filter of Paul Kellet) at `rms` dBFS RMS, from a seeded generator.
    static func pinkNoise(seconds: Int, rms: Double, seed: UInt64) -> [Float] {
        var random = SeededGenerator(seed: seed)
        var b = [Double](repeating: 0, count: 7)
        var out = [Double](repeating: 0, count: seconds * 16_000)
        for n in out.indices {
            let white = Double.random(in: -1...1, using: &random)
            b[0] = 0.99886 * b[0] + white * 0.0555179
            b[1] = 0.99332 * b[1] + white * 0.0750759
            b[2] = 0.96900 * b[2] + white * 0.1538520
            b[3] = 0.86650 * b[3] + white * 0.3104856
            b[4] = 0.55000 * b[4] + white * 0.5329522
            b[5] = -0.7616 * b[5] - white * 0.0168980
            out[n] = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + white * 0.5362
            b[6] = white * 0.115926
        }
        let actual = (out.reduce(0) { $0 + $1 * $1 } / Double(out.count)).squareRoot()
        let gain = pow(10, rms / 20) / actual
        return out.map { Float($0 * gain) }
    }
}

struct WhisperEngineTests {
    /// Gate 1 item 4. Piece n at p % is (n + p / 100) / count, and a value passes only when its
    /// whole percent grows, so a job gives at most about 100 values and ends at 1.
    @Test func eachPieceReportsItsPercentAndTheJobGrowsOncePerPercent() {
        var half: [Double] = []
        PieceProgress(count: 2) { half.append($0) }.update(piece: 0, percent: 50)
        #expect(half == [0.25])

        var values: [Double] = []
        let progress = PieceProgress(count: 3) { values.append($0) }
        for piece in 0..<3 {
            for percent in 0...100 { progress.update(piece: piece, percent: percent) }
            progress.update(piece: piece, percent: 100)
        }
        #expect(values.count <= 101 && values.last == 1)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 }, "\(values)")
        #expect(values.contains { $0 > 0 && $0 < 1.0 / 3 }, "a value inside piece 0")
    }

    /// Fix check 1.4 (c). The engine sets the whisper progress callback, so a piece of more than
    /// 30 s gives a value inside (0, 1) before the piece ends. With no callback, the only value is 1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aPieceOfMoreThanThirtySecondsReportsInsideThePiece() throws {
        let english = WhisperEngineBenchmark.english
        let speech = try WhisperEngineBenchmark.say(english + " " + english, voice: "Samantha", language: "en")
        try #require(speech.count > 32 * 16_000, "\(speech.count) samples of speech")
        let engine = try WhisperEngine(
            model: WhisperFixture.model(.tinyQ51), vad: WhisperFixture.vad, log: .disabled)
        var values: [Double] = []

        let result = try engine.transcribe(
            pieceCount: 1, language: .code("en"), stop: StopFlag(), read: { _ in speech },
            progress: { values.append($0) })

        #expect(result != nil)
        #expect(values.last == 1, "\(values)")
        #expect(values.dropLast().contains { $0 > 0 && $0 < 1 }, "no value inside the piece: \(values)")
    }

    @Test func aNonZeroCodeWithTheStopFlagIsAStop() {
        for code: Int32 in [-6, -3, -8, -9] {
            #expect(whisperOutcome(code: code, stopFlagSet: true) == .stopped, "code \(code)")
            #expect(whisperOutcome(code: code, stopFlagSet: false) == .failed(.engine(code: code)), "code \(code)")
        }
        #expect(whisperOutcome(code: 0, stopFlagSet: true) == .stopped)
        #expect(whisperOutcome(code: 0, stopFlagSet: false) == .finished)
    }

    @Test func aStopFlagReadsWhatASetWrote() {
        let flag = StopFlag()
        #expect(!flag.isSet && !cwhisper_stop_abort(flag.userData))
        flag.set()
        #expect(flag.isSet && cwhisper_stop_abort(flag.userData))
    }

    /// A model load that fails logs an error in whisper.cpp; it goes to the journal, not to stderr.
    @Test func aWhisperLogLineWritesNoStderrByte() throws {
        _ = WhisperLog.shared
        let folder = try TemporaryFolder()
        let capture = folder.url.appending(path: "stderr.txt")
        FileManager.default.createFile(atPath: capture.path, contents: nil)
        let saved = dup(STDERR_FILENO)
        let file = open(capture.path, O_WRONLY)
        fflush(stderr)
        dup2(file, STDERR_FILENO)
        let context = whisper_init_from_file_with_params(
            folder.url.appending(path: "missing.bin").path, whisper_context_default_params())
        fflush(stderr)
        dup2(saved, STDERR_FILENO)
        close(file)
        close(saved)
        #expect(context == nil)
        let written = try String(contentsOf: capture, encoding: .utf8)
        #expect(!written.contains("whisper"), "stderr: \(written)")
    }

    /// The push guard of the abort patch: with the flag set before `whisper_full`, the VAD stage
    /// stops at its first check. Without the patch, VAD runs over the whole piece first (about 10 s
    /// in the debug build for 120 s).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aStopFlagSetBeforeTheRunStopsWithinFiveSeconds() throws {
        let engine = try WhisperEngine(
            model: WhisperFixture.model(.tinyQ51), vad: WhisperFixture.vad, log: .disabled)
        let piece = WhisperFixture.pinkNoise(seconds: 120, rms: -40, seed: 120)
        let stop = StopFlag()
        stop.set()
        let start = ContinuousClock.now
        let outcome = try engine.transcribe(piece: piece, language: .automatic, stop: stop)
        let elapsed = ContinuousClock.now - start
        print("WhisperEngineTests push guard: stop to return \(elapsed)")
        #expect(outcome == .stopped)
        #expect(elapsed <= .seconds(5))
    }
}
