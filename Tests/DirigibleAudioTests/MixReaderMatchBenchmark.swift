import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Voice match C13 (decision 0074 D2): the match stage of 8 matched stereo tracks fits the refill
/// budgets of the Player, optimized (`make bench FILTER=MixReaderMatchBenchmark`). The cases time
/// `MixReader` as the Player calls it: a chunk of 0.1 s reads its span (`Player.swift`, the span of
/// `render`), a crossfade sets the old session and renders the chunk again, a play start makes a
/// new reader and renders 3 chunks, and a Match sets 8 new curves before a crossfade chunk. Budgets
/// at 48 kHz: p95 10 ms at 1x, 25 ms at 4x and with a crossfade, 50 ms for 8 new kernels. At 96 kHz
/// the chunk cases get 2.5 times those, capped at the refill tick of 50 ms, and the cases of 8 new
/// kernels only print. A debug build only prints.
struct MixReaderMatchBenchmark {
    #if DEBUG
        static let chunks = 30
        static let runs = 6
    #else
        static let chunks = 300
        static let runs = 60
    #endif

    /// 8 stereo tracks at `rate`, each matched to the tilt at amount 75, on 2 noise files. Each clip
    /// is 0.1 s long and starts in the middle of a 1x chunk, so each chunk holds 2 parts of each
    /// track. The clips cover `seconds`.
    static func fixture(rate: Int, seconds: Int) throws -> MixPackage {
        let package = try MixPackage(sampleRate: rate)
        let frames = rate * seconds
        try package.addFile(
            "a", channels: [MixReaderMatchTests.noise(frames, seed: 1), MixReaderMatchTests.noise(frames, seed: 2)])
        try package.addFile(
            "b", channels: [MixReaderMatchTests.noise(frames, seed: 3), MixReaderMatchTests.noise(frames, seed: 4)])
        let chunk = rate / 10
        var matches: [TrackID: VoiceMatch] = [:]
        for track in 0..<8 {
            let id = TrackID("t\(track)")
            try package.session.addTrack(id, name: id.rawValue, layout: .stereo)
            for index in 0..<(frames / chunk - 1) {
                let start = chunk / 2 + index * chunk
                try package.session.place(
                    Clip(
                        id: ClipID("\(id.rawValue)-\(index)"), file: FileID(index % 2 == 0 ? "a" : "b"),
                        start: Frames(start), offset: Frames(start), length: Frames(chunk)), on: id)
            }
            matches[id] = try curve(percent: 75)
        }
        try package.session.setMatch(matches)
        return package
    }

    static func curve(percent: Int) throws -> VoiceMatch {
        try VoiceMatch(
            amount: #require(VoiceMatch.Amount(percent)), reference: "Host 01",
            curve: (0..<25).map { -12 + Double($0) }, targetPowers: [Double](repeating: 1, count: 25))
    }

    /// The session with the amount of t0 at `percent`, or of each track with `all`.
    static func session(_ base: Session, percent: Int, all: Bool = false) throws -> Session {
        var session = base
        let tracks = all ? base.tracks.map(\.id) : ["t0"]
        try session.setMatchAmount(#require(VoiceMatch.Amount(percent)), tracks: tracks)
        return session
    }

    static func p95(_ times: [Duration]) -> Duration { times.sorted()[times.count * 95 / 100] }

    /// The chunk cases: 1x, 4x, a crossfade with a match change in each chunk (the Amount drag:
    /// 1 kernel design and 2 renders), and both.
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"), arguments: [48_000, 96_000])
    func chunkCasesFitTheBudget(rate: Int) throws {
        let chunk = rate / 10
        let package = try Self.fixture(rate: rate, seconds: Self.chunks * 4 / 10 + 2)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2))
        let span = chunk * 4 + 2
        let (buffer, fade) = try (
            #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(span))),
            #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(span)))
        )
        let scale = rate == 48_000 ? 1.0 : 2.5
        for (name, speed, crossfade, budget) in [
            ("1x", 1, false, 10.0), ("4x", 4, false, 25.0), ("crossfade", 1, true, 25.0),
            ("4x crossfade", 4, true, 25.0),
        ] {
            let reader = MixReader(package: package.url, session: package.session, span: span)
            let clock = ContinuousClock()
            var (times, previous, peak) = ([Duration](), package.session, Float(0))
            for index in 0..<Self.chunks {
                let first = index * chunk * speed
                let range = Frames(first)..<Frames(first + chunk * speed + (speed == 1 ? 1 : 2))
                let next = try crossfade ? Self.session(package.session, percent: 1 + index % 99) : previous
                let start = clock.now
                if crossfade { reader.session = next }
                reader.render(range, into: buffer)
                if crossfade {
                    reader.session = previous
                    reader.render(range, into: fade)
                    reader.session = next
                }
                times.append(clock.now - start)
                previous = next
                peak = max(peak, abs(buffer.floatChannelData![0][chunk / 4]))
            }
            let limit = Duration.milliseconds(min(50, budget * scale))
            print("MixReaderMatchBenchmark \(rate) Hz \(name): p95 \(Self.p95(times)), budget \(limit)")
            #expect(peak > 0, "the chunks hold audio")
            expectWithinBudget(Self.p95(times), limit, "voice match \(rate) Hz \(name): p95 \(Self.p95(times))")
        }
    }

    /// The cases of 8 new kernels: a cold start (a new reader with its 8 designs and its first
    /// refill of 3 chunks) and a Match of 8 tracks (8 new curves, then a crossfade chunk), at 1x and
    /// 4x. At 96 kHz they only print (C13: the app makes only 48 kHz sessions).
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"), arguments: [48_000, 96_000])
    func newKernelCasesFitTheBudget(rate: Int) throws {
        let chunk = rate / 10
        let package = try Self.fixture(rate: rate, seconds: 6)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2))
        let span = chunk * 4 + 2
        let (buffer, fade) = try (
            #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(span))),
            #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(span)))
        )
        let clock = ContinuousClock()
        for speed in [1, 4] {
            let read = chunk * speed + (speed == 1 ? 1 : 2)
            var cold: [Duration] = []
            for _ in 0..<Self.runs {
                let start = clock.now
                let reader = MixReader(package: package.url, session: package.session, span: span)
                for index in 0..<3 { reader.render(Frames(index * read)..<Frames((index + 1) * read), into: buffer) }
                cold.append(clock.now - start)
            }
            let reader = MixReader(package: package.url, session: package.session, span: span)
            var (match, old) = ([Duration](), package.session)
            for run in 0..<Self.runs {
                let new = try Self.session(package.session, percent: 1 + run, all: true)
                let range = Frames(read)..<Frames(2 * read)
                let start = clock.now
                reader.session = new
                reader.render(range, into: buffer)
                reader.session = old
                reader.render(range, into: fade)
                reader.session = new
                match.append(clock.now - start)
                old = new
            }
            for (name, times) in [("cold start", cold), ("Match of 8 tracks", match)] {
                let line = "\(rate) Hz \(name) at \(speed)x: p95 \(Self.p95(times))"
                print("MixReaderMatchBenchmark \(line), budget \(rate == 48_000 ? "50 ms" : "none")")
                if rate == 48_000 { expectWithinBudget(Self.p95(times), .milliseconds(50), line) }
            }
        }
    }

    /// C14 pass count for probe P2 and check M2: an export of the package at `DIRIGIBLE_CORPUS`, with
    /// the tilt at 75 % on its first two tracks, to WAV with the podcast target. It prints the mix
    /// passes (`tuning.onStep`) and the time.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_CORPUS"] != nil))
    func exportWithTarget() throws {
        let url = URL(filePath: try #require(ProcessInfo.processInfo.environment["DIRIGIBLE_CORPUS"]))
        var session = try Session(contentsOf: url)
        let tracks = session.tracks.prefix(2).map(\.id)
        let match = try Self.curve(percent: 75)
        try session.setMatch(Dictionary(uniqueKeysWithValues: tracks.map { ($0, match) }))
        let folder = try TemporaryFolder()
        var steps: [LoudnessSearch.Step] = []
        var tuning = ExportTuning()
        tuning.onStep = { steps.append($0) }
        let clock = ContinuousClock()
        let start = clock.now
        let result = try exportMix(
            session, source: #require(ExportSource(range: 0..<session.end)),
            options: ExportOptions(format: .wav(.bits16), layout: .stereo, rate: .session, loudness: .podcast),
            to: folder.url.appending(path: "mix.wav"), package: { url }, tuning: tuning)
        let trials = steps.filter { if case .trial = $0 { true } else { false } }.count
        let writes = steps.filter { if case .write = $0 { true } else { false } }.count
        print(
            "MixReaderMatchBenchmark: export of \(tracks.map(\.rawValue)) with podcast in \(clock.now - start): "
                + "\(1 + trials + writes) mix passes, \(trials) trial passes, \(writes) writes")
        #expect(result.faults == [:])
    }
}
