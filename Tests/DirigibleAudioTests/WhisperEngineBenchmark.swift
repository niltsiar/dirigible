import Foundation
import Testing
import os

@testable import DirigibleAudio

/// The engine cases of decision 0065 on real models (`scripts/fetch-whisper-test-model.sh` first),
/// run with `make bench FILTER='WhisperEngineBenchmark TranscribeBenchmark'`. In the debug build,
/// C15, C16, and the NaN case run; the cases that take a minute or more skip with a printed reason,
/// and no time bound asserts.
struct WhisperEngineBenchmark {
    static let english = """
        The morning train left the station at seven, carrying commuters who read newspapers and drank \
        coffee from paper cups. Outside the windows, fields of wheat moved gently in the wind, and a farmer \
        waved at the passing cars. By the time the train reached the city, the sun was high and the streets \
        were full of people walking to work.
        """
    static let spanish = """
        El tren de la mañana salió de la estación a las siete, lleno de viajeros que leían el periódico y \
        bebían café en vasos de papel. Por las ventanas se veían campos de trigo que se movían con el viento, \
        y un campesino saludaba a los coches. Cuando el tren llegó a la ciudad, el sol estaba alto y las \
        calles estaban llenas de gente.
        """
    static let c24Words = [
        "apple", "river", "window", "garden", "yellow", "thunder", "pencil", "morning", "silver", "candle",
        "forest", "button", "orange", "winter", "dragon", "kitchen", "marble", "rocket", "violin", "harbor",
    ]

    /// 16 kHz mono speech of `say`. A missing voice fails with `no say voice for <language>`.
    /// `say` starts through `posix_spawn`: `Process` gives each argument in NFD, and `say` reads an NFD
    /// voice name ("Mónica") as an unknown voice and speaks with the default voice, with exit 0.
    static func say(_ text: String, voice: String, language: String) throws -> [Float] {
        let voices = try run("/usr/bin/say", ["-v", "?"])
        try #require(
            voices.split(separator: "\n").contains { $0.hasPrefix(voice + " ") }, "no say voice for \(language)")
        let folder = try TemporaryFolder()
        let file = folder.url.appending(path: "say.wav")
        let arguments: [String] = [
            "/usr/bin/say", "-v", voice, "--file-format=WAVE", "--data-format=LEF32@16000", "-o", file.path, text,
        ]
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        defer { for pointer in argv { free(pointer) } }
        var pid = pid_t()
        let spawn = posix_spawn(&pid, "/usr/bin/say", nil, nil, argv + [nil], environ)
        try #require(spawn == 0, "posix_spawn say: \(spawn)")
        var status: Int32 = 0
        try #require(waitpid(pid, &status, 0) == pid)
        try #require(status == 0, "say wait status \(status)")
        let audio = try readAudio(file)
        try #require(audio.rate == 16_000)
        return audio.samples
    }

    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(tool) \(arguments.prefix(2)) exit \(process.terminationStatus)")
        return String(decoding: data, as: UTF8.self)
    }

    static func engine(_ model: WhisperModel = .base, vad: Bool = true) throws -> WhisperEngine {
        try WhisperEngine(model: WhisperFixture.model(model), vad: vad ? WhisperFixture.vad : nil, log: .disabled)
    }

    static func words(_ outcome: PieceOutcome) throws -> (words: [TimedWord], language: String) {
        guard case .words(let words, let language) = outcome else {
            Issue.record("the piece stopped")
            throw CancellationError()
        }
        return (words, language)
    }

    /// The word error rate after lower case, with punctuation dropped and "7" read as the word.
    static func wordErrorRate(_ reference: String, _ words: [TimedWord], seven: String) -> Double {
        func normal(_ text: String) -> [String] {
            text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map {
                $0 == "7" ? seven : String($0)
            }
        }
        let ref = normal(reference)
        let hyp = normal(words.map(\.text).joined(separator: " "))
        var row = Array(0...hyp.count)
        for i in 1...ref.count {
            var next = [i] + Array(repeating: 0, count: hyp.count)
            for j in 1...max(hyp.count, 1) where !hyp.isEmpty {
                next[j] = min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1))
            }
            row = next
        }
        return Double(row[hyp.count]) / Double(ref.count)
    }

    static func skipInDebug(_ reason: String) -> Bool {
        #if DEBUG
            print("WhisperEngineBenchmark skip in the debug build: \(reason)")
            return true
        #else
            return false
        #endif
    }

    // MARK: Cases that run in the debug build

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func sayReadsWithTheVoiceOfANameWithAnAccent() throws {
        let phrase = "Hola, buenas tardes."
        let folder = try TemporaryFolder()
        let file = folder.url.appending(path: "reference.wav")
        // The octal escapes give say the NFC bytes of "Mónica" with no argument conversion of Process.
        let script = """
            /usr/bin/say -v "$(printf 'M\\303\\263nica')" --file-format=WAVE --data-format=LEF32@16000 -o "$0" "$1"
            """
        _ = try Self.run("/bin/sh", ["-c", script, file.path, phrase])
        let reference = try readAudio(file).samples
        let samples = try Self.say(phrase, voice: "Mónica", language: "es")
        let same = samples.count == reference.count && zip(samples, reference).allSatisfy { abs($0 - $1) <= 1e-6 }
        #expect(same, "\(samples.count) samples of the helper, \(reference.count) of Mónica")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func c15TheFirstWordStartsAtTheOnset() throws {
        let speech = try Self.say("Hello everyone, and welcome to the show.", voice: "Samantha", language: "en")
        let piece = [Float](repeating: 0, count: 16_000) + speech
        let onset = try #require(piece.firstIndex { abs($0) > 0.01 })
        let words = try Self.words(Self.engine().transcribe(piece: piece, language: .code("en"), stop: StopFlag()))
        let first = try #require(words.words.first)
        #expect(abs(Double(first.start) / 100 - Double(onset) / 16_000) <= 0.25, "start \(first.start) onset \(onset)")
        #expect(words.words.allSatisfy { $0.start < $0.end })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func c16SilenceAndNoiseGiveNoWord() throws {
        let piece =
            [Float](repeating: 0, count: 60 * 16_000) + WhisperFixture.pinkNoise(seconds: 30, rms: -40, seed: 16)
        let words = try Self.words(Self.engine().transcribe(piece: piece, language: .code("en"), stop: StopFlag()))
        #expect(words.words.isEmpty, "\(words.words.map(\.text))")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aPieceWithNaNSamplesTranscribes() throws {
        var piece = try Self.say("Hello everyone, and welcome to the show.", voice: "Samantha", language: "en")
        for n in stride(from: 0, to: piece.count, by: 997) { piece[n] = n % 2 == 0 ? .nan : .infinity }
        let words = try Self.words(
            Self.engine(.tinyQ51).transcribe(piece: piece, language: .code("en"), stop: StopFlag()))
        #expect(!words.words.isEmpty)
    }

    // MARK: Cases of the optimized build

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func c13AutomaticDetectsSpanish() throws {
        if Self.skipInDebug("C13 takes about 60 s") { return }
        let piece = try Self.say(Self.spanish, voice: "Mónica", language: "es")
        #expect(
            try Self.words(Self.engine().transcribe(piece: piece, language: .automatic, stop: StopFlag())).language
                == "es")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func c14TheWordErrorRateIsAtMostFifteenPercent() throws {
        if Self.skipInDebug("C14 takes about 54 s") { return }
        let engine = try Self.engine()
        for (text, voice, language, seven) in [
            (Self.english, "Samantha", "en", "seven"), (Self.spanish, "Mónica", "es", "siete"),
        ] {
            let piece = try Self.say(text, voice: voice, language: language)
            let words = try Self.words(engine.transcribe(piece: piece, language: .code(language), stop: StopFlag()))
            let rate = Self.wordErrorRate(text, words.words, seven: seven)
            print("WhisperEngineBenchmark C14 \(language): word error rate \(rate)")
            #expect(rate <= 0.15, "\(language): \(rate)")
        }
    }

    /// The C24 fixture: each word of `say`, joined with seeded silences of 0.3 s to 0.6 s. The end
    /// of a word is its last sample over -40 dBFS.
    static func c24Fixture() throws -> (samples: [Float], ends: [Double]) {
        var random = SeededGenerator(seed: 24)
        var samples = [Float](repeating: 0, count: 8_000)
        var ends: [Double] = []
        for word in c24Words {
            let speech = try say(word, voice: "Samantha", language: "en")
            let first = try #require(speech.firstIndex { abs($0) > 0.01 })
            let last = try #require(speech.lastIndex { abs($0) > 0.01 })
            samples += speech[first...last]
            ends.append(Double(samples.count) / 16_000)
            samples += [Float](repeating: 0, count: Int.random(in: 4_800...9_600, using: &random))
        }
        return (samples, ends)
    }

    static let noises: [Double?] = [nil, -45, -35]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"), arguments: Self.noises)
    func c24WordEndsAreWithinTheBound(noise: Double?) throws {
        if Self.skipInDebug("C24 takes about 84 s") { return }
        var (piece, ends) = try Self.c24Fixture()
        if let noise {
            let pink = WhisperFixture.pinkNoise(
                seconds: piece.count / 16_000 + 1, rms: noise, seed: noise == -35 ? 3501 : 45)
            for n in piece.indices { piece[n] += pink[n] }
        }
        let words = try Self.words(Self.engine().transcribe(piece: piece, language: .code("en"), stop: StopFlag()))
            .words
        #expect(words.allSatisfy { $0.start < $0.end })
        let matched = words.compactMap { word -> Double? in
            let text = word.text.lowercased().filter(\.isLetter)
            guard let k = Self.c24Words.firstIndex(of: text == "harbour" ? "harbor" : text) else { return nil }
            return abs(Double(word.end) / 100 - ends[k])
        }
        let mean = matched.reduce(0, +) / Double(max(matched.count, 1))
        let largest = matched.max() ?? 1
        let label = noise.map { "\($0) dBFS" } ?? "none"
        print("WhisperEngineBenchmark C24 noise \(label): \(matched.count) of 20, mean \(mean), largest \(largest)")
        #expect(matched.count >= 19 && mean <= 0.10 && largest <= 0.25)
    }

    /// C10: the time from the flag set to the return of `whisper_full` is at most 2 s.
    static let stops = [(600, true, 0.0), (600, false, 0.0), (180, true, 0.3)]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"), arguments: Self.stops)
    func c10AStopReturnsWithinTwoSeconds(seconds: Int, vad: Bool, at fraction: Double) throws {
        if Self.skipInDebug("the C10 stop cases take 29 s to 141 s") { return }
        let speech = try Self.say(Self.spanish, voice: "Mónica", language: "es")
        var piece: [Float] = []
        while piece.count < seconds * 16_000 { piece += speech }
        piece.removeLast(piece.count - seconds * 16_000)
        let engine = try Self.engine(vad: vad)
        let stop = StopFlag()
        // The engine has no progress hook, so the 30 % case stops by a timer at 9.5 s of the 180 s
        // run, an encoder point of the stop probe sweep (0.116 s there).
        let delay = fraction > 0 ? 9.5 : 0
        let setAt = StopTime()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            setAt.set(.now)
            stop.set()
        }
        let outcome = try engine.transcribe(piece: piece, language: .code("es"), stop: stop)
        let returned = ContinuousClock.now
        let latency = try returned - #require(setAt.get())
        print("WhisperEngineBenchmark C10 \(seconds) s vad \(vad) at \(fraction): stop to return \(latency)")
        #expect(outcome == .stopped)
        #expect(latency <= .seconds(2))
    }
}

/// The time of a stop, set on one thread and read on another.
final class StopTime: Sendable {
    private let value = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
    func set(_ instant: ContinuousClock.Instant) { value.withLock { $0 = instant } }
    func get() -> ContinuousClock.Instant? { value.withLock { $0 } }
}
