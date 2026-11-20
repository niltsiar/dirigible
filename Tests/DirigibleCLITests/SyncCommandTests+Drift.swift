import AVFoundation
import Accelerate
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleMCP

/// `dirigible clip sync --drift` (decision 0077 D12). The drift package is that of
/// `StudioDriftTests`: track `ref` holds clip `R` (file `r`, the signal at session
/// time), and track `guest` holds clip `C` (file `c`, the same signal on a clock of 100 ppm), 1.2345 s
/// early. With a pause, the clip skips that many seconds of the signal there.
extension SyncCommandTests {
    private static let driftRate = 48_000
    private static let driftOffset = Int(1.2345 * Double(driftRate))
    private static let ppm = 100.0

    /// The audio folders of the drift packages, written once for each shape: seconds, pause, and
    /// clip second of the pause.
    private static let driftAudio = DriftAudioCache()

    /// A package with the drift audio in `Clips/`.
    static func driftPackage(seconds: Int, pause: Int = 0, at pauseSeconds: Int = 0) throws -> TemporaryPackage {
        let shape = DriftShape(seconds: seconds, pause: pause, pauseSeconds: pauseSeconds)
        let folder = try driftAudio.folder(of: shape)
        var session = Session(sampleRate: driftRate)
        for (id, file, track, start, length) in [
            ("R", "r", "ref", 0, shape.referenceLength),
            ("C", "c", "guest", 30 * driftRate - driftOffset, shape.length),
        ] {
            try session.addFile(
                AudioFile(id: FileID(file), path: "\(file).wav", layout: .mono, length: Frames(length)))
            try session.addTrack(TrackID(track), name: track, layout: .mono)
            try session.place(
                Clip(id: ClipID(id), file: FileID(file), start: Frames(start), offset: 0, length: Frames(length)),
                on: TrackID(track))
        }
        let package = try TemporaryPackage(session)
        try FileManager.default.createDirectory(
            at: package.url.appending(path: "Clips"), withIntermediateDirectories: true)
        for file in ["c", "r"] {
            try FileManager.default.copyItem(
                at: folder.appending(path: "\(file).wav"), to: package.url.appending(path: "Clips/\(file).wav"))
        }
        return package
    }

    /// `clip sync C --to ref --drift` with `options`. A fix in a debug build takes minutes, so the limit is 15 min.
    static func drift(_ package: TemporaryPackage, _ options: String...) async throws -> CLIResult {
        try await dirigible(
            shell: #"exec "$0" "$@""#,
            arguments: [dirigibleBinary.path, "clip", "sync", package.path, "C", "--to", "ref", "--drift"] + options,
            limit: .seconds(900))
    }

    /// The first line moves the clip later by the offset of the package, then the fix line says the
    /// rate, the change across the clip, and that one resample made the new file, and the session
    /// plays that file with a drift link to the old one. The JSON has the same fix in `drift_correction`.
    @Test func driftCorrectsAnOutsideRecording() async throws {
        let package = try Self.driftPackage(seconds: 300)

        let result = try await Self.drift(package)

        let lines = result.stdout.split(separator: "\n").map(String.init)
        #expect(result.status == 0 && result.stderr == "", "\(result)")
        #expect(
            lines.first?.wholeMatch(of: /moved C by \+1\.\d{3} s \(\d+ frames\), match \d\.\d\d/) != nil, "\(lines)")
        let fixed =
            /corrected a drift of \+(?:99\.9|100\.0|100\.1) ppm \(30 ms across the clip\) in one resample; the lag stays within \d\.\d ms of the line/
        #expect(lines.contains { $0.wholeMatch(of: fixed) != nil }, "\(lines)")
        #expect(!lines.contains { $0.hasPrefix("split the clip") || $0.hasPrefix("the drift was not corrected") })
        let session = try package.read()
        let file = try #require(session.clip("C").flatMap { session.files[$0.clip.file] }, "\(lines)")
        #expect(file.path == "c drift.wav" && file.drift?.source == "c", "\(file)")
        #expect(FileManager.default.fileExists(atPath: package.url.appending(path: "Clips/c drift.wav").path))

        let json = try await Self.drift(try Self.driftPackage(seconds: 300), "--json")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any], "\(json)")
        let correction = try #require(object["drift_correction"] as? [String: Any], "\(object)")
        #expect(Set(correction.keys) == ["ppm", "across_ms", "segments", "worst_ms"], "\(correction)")
        #expect(abs((correction["ppm"] as? Double ?? 0) - Self.ppm) <= 0.1 && correction["across_ms"] as? Int == 30)
        #expect(correction["segments"] as? Int == 1 && (correction["worst_ms"] as? Double ?? 9) < 1, "\(correction)")
        #expect(object["drift_not_corrected"] == nil && object["clip"] as? String == "C")
    }

    /// A clip under 5 min moves by the lag, writes no file, and the text and the JSON give the cause.
    @Test func driftNotCorrectedSaysWhy() async throws {
        let text = try Self.package(reference: "r-full")
        let json = try Self.package(reference: "r-full")
        let names = try FileManager.default.contentsOfDirectory(atPath: text.url.appending(path: "Clips").path).sorted()

        let result = try await Self.drift(text)
        let jsonResult = try await Self.drift(json, "--json")

        let moved =
            /moved C by -20\.000 s \(-960000 frames\), match \d\.\d\d\nthe drift was not corrected: the clip is shorter than 5 min\n/
        #expect(result.status == 0 && result.stderr == "" && result.stdout.wholeMatch(of: moved) != nil, "\(result)")
        #expect(try text.read().clip("C")?.clip.start == 480_000)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: text.url.appending(path: "Clips").path).sorted()
                == names, "a file was written")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(jsonResult.stdout.utf8)) as? [String: Any], "\(jsonResult)")
        #expect(object["drift_correction"] is NSNull && object["frames"] as? Int == -960_000, "\(object)")
        #expect(object["drift_not_corrected"] as? String == "the clip is shorter than 5 min", "\(object)")
    }

    /// A 12 min clip, with a pause of 20 s at clip second 330. The text gives one split line
    /// with the clip time of the cut and the length of the pause, and the session has two clips.
    @Test func aPauseGivesASplitLine() async throws {
        let package = try Self.driftPackage(seconds: 720, pause: 20, at: 330)

        let result = try await Self.drift(package)

        let lines = result.stdout.split(separator: "\n").map(String.init)
        let splits = lines.filter { $0.hasPrefix("split the clip") }
        #expect(result.status == 0 && result.stderr == "", "\(result)")
        #expect(
            splits.count == 1
                && splits[0].wholeMatch(
                    of: /split the clip at 5:(?:29|30|31)\.\d{3} \(the recording paused (?:19\.999|20\.00[01]) s\)/)
                    != nil,
            "\(lines)")
        #expect(lines.contains { $0.contains("in 2 resamples; the lag stays within") }, "\(lines)")
        let session = try package.read()
        #expect(session.tracks.first { $0.id == "guest" }?.clips.count == 2, "\(lines)")
    }

    /// With no `--drift`, the text and the JSON are those of 0076: no drift line and no
    /// `drift_correction` key.
    @Test func noDriftFlagKeepsTheOldOutput() async throws {
        let text = try Self.package(reference: "r-full")
        let json = try Self.package(reference: "r-full")

        let result = try await text.run("clip", "sync", "PKG", "C", "--to", "ref")
        let jsonResult = try await json.run("clip", "sync", "PKG", "C", "--to", "ref", "--json")

        let moved = /moved C by -20\.000 s \(-960000 frames\), match \d\.\d\d\n/
        #expect(result.stdout.wholeMatch(of: moved) != nil, "\(result)")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(jsonResult.stdout.utf8)) as? [String: Any], "\(jsonResult)")
        #expect(
            Set(object.keys) == ["clip", "frames", "seconds", "match", "spread", "headCut", "replaced"], "\(object)")
    }
}

/// The shape of a drift package: the clip seconds, and a pause of `pause` seconds at clip second
/// `pauseSeconds`.
private struct DriftShape: Hashable {
    let seconds: Int
    let pause: Int
    let pauseSeconds: Int
    var length: Int { seconds * 48_000 }

    /// The seconds of the signal at clip frame `c`: the clip reads it at a clock of 1 + 100 ppm.
    func sourceTime(_ c: Double) -> Double {
        let skipped = pause > 0 && c >= Double(pauseSeconds * 48_000) ? Double(pause) : 0
        return 30 + c * (1 + 100e-6) / 48_000 + skipped
    }

    var referenceLength: Int { Int((sourceTime(Double(length)) + 30) * 48_000) }
}

/// The folder of the WAV files of each shape, written once for the process.
private final class DriftAudioCache: @unchecked Sendable {
    private let lock = NSLock()
    private var folders: [DriftShape: URL] = [:]

    func folder(of shape: DriftShape) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        if let folder = folders[shape] { return folder }
        let folder = FileManager.default.temporaryDirectory.appending(path: "SyncDrift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let voice = DriftSignal(seed: 1, seconds: 30 + Double(shape.seconds) * 1.01 + Double(shape.pause) + 60)
        try writeWAV(folder.appending(path: "r.wav"), length: shape.referenceLength) {
            voice.samples(start: Double($0.lowerBound) / 48_000, step: 1 / 48_000, count: $0.count)
        }
        let step = (1 + 100e-6) / 48_000
        let pauseAt = shape.pause > 0 ? shape.pauseSeconds * 48_000 : .max
        try writeWAV(folder.appending(path: "c.wav"), length: shape.length) { range in
            let split = min(max(pauseAt, range.lowerBound), range.upperBound)
            return [range.lowerBound..<split, split..<range.upperBound].filter { !$0.isEmpty }.flatMap {
                voice.samples(start: shape.sourceTime(Double($0.lowerBound)), step: step, count: $0.count)
            }
        }
        folders[shape] = folder
        return folder
    }
}

/// Writes a mono 24-bit WAV at 48 kHz of `length` frames in blocks from `samples`.
private func writeWAV(_ url: URL, length: Int, samples: (Range<Int>) -> [Float]) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(
        forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let block = 1 << 20
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(block)))
    for first in stride(from: 0, to: length, by: block) {
        let frames = samples(first..<min(first + block, length))
        buffer.frameLength = AVAudioFrameCount(frames.count)
        buffer.floatChannelData![0].update(from: frames, count: frames.count)
        try file.write(from: buffer)
    }
}

/// The voice of `DriftSignal.swift` in `DirigibleAudioTests`: a
/// seeded syllable envelope, on for 150 to 400 ms and off for 100 to 600 ms, over 40 seeded sines
/// from 100 to 3400 Hz for each on or off span. A sample is a function of its time in seconds, so a
/// clip at a clock of 1 + m needs no resampler.
private struct DriftSignal {
    private static let sines = 40
    private let carrier: [Double]
    private let frequencies: [Double]
    private let phases: [Double]
    private let speech: [Range<Double>]

    init(seed: UInt64, seconds: Double) {
        var random = SeededGenerator(seed: seed)
        var (speech, carrier, frequencies, phases) = ([Range<Double>](), [Double](), [Double](), [Double]())
        var time = 0.0
        while time < seconds {
            let on = Double.random(in: 0.150...0.400, using: &random)
            let off = Double.random(in: 0.100...0.600, using: &random)
            speech.append(time..<time + on)
            carrier += [time, time + on]
            for _ in 0..<2 * Self.sines {
                let position: Double = Double.random(in: 0..<1, using: &random)
                frequencies.append(100 * pow(34.0, position))
                phases.append(Double.random(in: 0..<(2 * .pi), using: &random))
            }
            time += on + off
        }
        (self.speech, self.carrier, self.frequencies, self.phases) = (speech, carrier, frequencies, phases)
    }

    /// `count` samples at the times `start + n x step` seconds. Only the frames where the envelope is
    /// on get sines.
    func samples(start: Double, step: Double, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let end = start + Double(count) * step
        var part = 0
        for span in speech where span.upperBound > start && span.lowerBound < end {
            let on = frames(of: span, start: start, step: step, count: count)
            while part + 1 < carrier.count && carrier[part + 1] <= span.lowerBound { part += 1 }
            var next = part
            while next < carrier.count && carrier[next] < min(span.upperBound, end) {
                let upper = next + 1 < carrier.count ? min(carrier[next + 1], end) : end
                let carried = frames(of: carrier[next]..<upper, start: start, step: step, count: count)
                addSines(of: next, to: &out, in: carried.clamped(to: on), start: start, step: step)
                next += 1
            }
        }
        return out
    }

    private func frames(of span: Range<Double>, start: Double, step: Double, count: Int) -> Range<Int> {
        let low = min(count, max(0, Int(((span.lowerBound - start) / step).rounded(.up))))
        let high = min(count, Int(((span.upperBound - start) / step).rounded(.up)))
        return low..<max(low, high)
    }

    private func addSines(of part: Int, to out: inout [Float], in frames: Range<Int>, start: Double, step: Double) {
        let block = 4096
        var phase = [Float](repeating: 0, count: block)
        var amplitude: Float = 0.02
        let sines = part * Self.sines..<(part + 1) * Self.sines
        out.withUnsafeMutableBufferPointer { out in
            for first in stride(from: frames.lowerBound, to: frames.upperBound, by: block) {
                let n = min(block, frames.upperBound - first)
                let time = start + Double(first) * step
                for (frequency, offset) in zip(frequencies[sines], phases[sines]) {
                    let turn: Double = 2 * Double.pi
                    let radians: Double = turn * frequency * time + offset
                    var begin = Float(radians.truncatingRemainder(dividingBy: turn))
                    var increment = Float(turn * frequency * step)
                    vDSP_vramp(&begin, &increment, &phase, 1, vDSP_Length(n))
                    var length = Int32(n)
                    phase.withUnsafeMutableBufferPointer { vvsinf($0.baseAddress!, $0.baseAddress!, &length) }
                    let target = out.baseAddress! + first
                    vDSP_vsma(phase, 1, &amplitude, target, 1, target, 1, vDSP_Length(n))
                }
            }
        }
    }
}

/// A repeatable generator for the signal: the same seed gives the same signal.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
