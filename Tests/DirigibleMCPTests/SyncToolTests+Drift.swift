import AVFoundation
import Accelerate
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// The tool `clip_sync` with `drift` (decision 0077 D12). The drift package is that of
/// `StudioDriftTests` with 300 s of audio: clip `C` (file `c`) is on `t1`, and clip `R` (file
/// `r`, the signal at session time) is on `t2`. The audio of `C` is the same signal on a clock of 100 ppm,
/// 1.2345 s early.
extension SyncToolTests {
    private static let driftRate = 48_000
    private static let driftOffset = Int(1.2345 * Double(driftRate))
    private static let driftSeconds = 300

    /// The WAV files of the drift package, written once for the process.
    private static let driftAudio = Result { try writeDriftAudio() }

    /// The first line and the fix line of a result for `driftPackage`.
    static let movedLine = /moved C by \+1\.\d{3} s \(\d+ frames\), match \d\.\d\d/
    static let fixLine =
        /corrected a drift of \+(?:99\.9|100\.0|100\.1) ppm \(30 ms across the clip\) in one resample; the lag stays within \d\.\d ms of the line/

    /// A package with the drift audio in `Clips/`.
    static func driftPackage() throws -> LivePackage {
        let package = try LivePackage()
        var session = try Session(contentsOf: package.url)
        let length = Frames(driftSeconds * driftRate)
        let reference = Frames(try driftAudio.get().referenceLength)
        for (id, track, start, frames) in [
            ("r", "t2", 0, reference), ("c", "t1", Frames(30 * driftRate - driftOffset), length),
        ] {
            try session.addFile(AudioFile(id: FileID(id), path: "\(id).wav", layout: .mono, length: frames))
            try session.place(
                Clip(id: id == "r" ? "R" : "C", file: FileID(id), start: start, offset: 0, length: frames),
                on: TrackID(track))
        }
        try session.write(to: package.url)
        let clips = package.url.appending(path: "Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        for file in ["c", "r"] {
            try FileManager.default.copyItem(
                at: try driftAudio.get().folder.appending(path: "\(file).wav"), to: clips.appending(path: "\(file).wav")
            )
        }
        return package
    }

    /// The reply of `clip_sync` of `C` to `t2` with `drift` on the files, off the main actor.
    func closedDrift(_ package: LivePackage) async -> (text: String, isError: Bool) {
        let tool = Tool.all.first { $0.name == "clip_sync" }
        let path = package.path
        return await onThread {
            let json: [String: Any] = ["package": path, "clip": "C", "to": "t2", "drift": true]
            let control = CallControl(token: nil, interval: .zero, send: { _ in }, poll: { _ in false }, step: {})
            return tool?.call(json, control: control) ?? ("no tool clip_sync", true)
        }
    }

    /// `drift` true on the files gives the lines of `dirigible clip sync --drift` and saves a session
    /// whose clip plays the new file.
    @Test func driftOnAClosedPackage() async throws {
        let package = try Self.driftPackage()

        let answer = await closedDrift(package)

        let lines = answer.text.split(separator: "\n").map(String.init)
        #expect(!answer.isError && lines.count >= 2, "\(answer)")
        #expect(lines.first?.wholeMatch(of: Self.movedLine) != nil, "\(answer)")
        #expect(lines.contains { $0.wholeMatch(of: Self.fixLine) != nil }, "\(answer)")
        let session = try Session(contentsOf: package.url)
        let file = try #require(session.clip("C").flatMap { session.files[$0.clip.file] }, "\(answer)")
        #expect(file.path == "c drift.wav" && file.drift?.source == "c", "\(file)")
        #expect(FileManager.default.fileExists(atPath: package.url.appending(path: "Clips/c drift.wav").path))
    }

    /// On an open session the call is a long job with progress that grows, and the same lines come
    /// back. The fix is one undo step with the agent name, and the undo puts back the old file.
    @Test func driftOnAnOpenSessionIsALongJob() async throws {
        let package = try Self.driftPackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let (sent, socket, path) = (Sent(), folder.socket, package.path)
        let before = studio.session

        let outcome = await Task {
            await onThread {
                let control = CallControl(token: 1, interval: .zero, send: sent.send, poll: { _ in false }, step: {})
                return AgentBridge(socket: socket, timeout: .seconds(600)).call(
                    tool: "clip_sync", arguments: ["package": path, "clip": "C", "to": "t2", "drift": true],
                    client: testClient, control: control)
            }
        }.value

        guard case .reply(.result(let text, false)) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.first?.wholeMatch(of: Self.movedLine) != nil, "\(text)")
        #expect(lines.contains { $0.wholeMatch(of: Self.fixLine) != nil }, "\(text)")
        let values = sent.progress(token: 1)
        #expect(!values.isEmpty && values == values.sorted() && values.max() ?? 0 > 0.5, "\(values)")
        #expect(studio.session.clip("C")?.clip.file == "c drift" && studio.undoAgent?.name == "Test Agent")
        try studio.undo()
        #expect(studio.session == before && !studio.canUndo, "the fix is more than one undo step")
        await studio.settle()
    }

    /// A drift-corrected file has a `drift` key in `session_info` with its source, offset, ratio,
    /// and added gain, and `info` has them in the text of its file line. A plain file has neither.
    @Test func infoShowsTheDriftLink() async throws {
        let package = try LivePackage()
        var session = try Session(contentsOf: package.url)
        try session.addFile(AudioFile(id: "guest", path: "guest.wav", layout: .mono, length: 28_800_000))
        let link = DriftOrigin(
            source: "guest", offset: 48_000, ratio: try #require(DriftRatio(0.9999)),
            addedGain: try #require(Gain(dB: 3.01)))
        try session.addFile(
            AudioFile(id: "guest drift", path: "guest drift.wav", layout: .mono, length: 28_700_000, drift: link))
        try session.place(Clip(id: "C", file: "guest drift", start: 0, offset: 0, length: 48_000), on: "t1")
        try session.write(to: package.url)
        let tool = try #require(Tool.all.first { $0.name == "session_info" })
        let path = package.path

        let answer = await onThread {
            let control = CallControl(token: nil, interval: .zero, send: { _ in }, poll: { _ in false }, step: {})
            return tool.call(["package": path], control: control)
        }

        let view = try #require(try JSONSerialization.jsonObject(with: Data(answer.text.utf8)) as? [String: Any])
        let files = try #require(view["files"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: files.map { ($0["id"] as? String ?? "", $0) })
        let expected: NSDictionary = ["source": "guest", "offset": 48_000, "ratio": 0.9999, "gain": 3.01]
        #expect(!answer.isError && byID["guest drift"]?["drift"] as? NSDictionary == expected, "\(answer)")
        #expect(byID["guest"]?["drift"] == nil && byID["guest"]?["origin"] == nil)
        let text = summary(
            of: session, name: "Show.dirigible", media: [:],
            takeMap: TakeMap.of(session, anchors: TakeAnchors.result(package.url)),
            raw: [:], archive: nil)
        let fileLines = text.split(separator: "\n").filter { $0.hasPrefix("file ") }
        #expect(
            fileLines == [
                #"file guest "guest.wav" mono length 28800000"#,
                #"file guest drift "guest drift.wav" mono length 28700000 drift guest offset 48000 ratio 0.9999 added gain 3.01 dB"#,
            ], "\(text)")
    }
}

/// The folder of the drift WAV files and the length of the reference file.
private struct DriftAudio {
    let folder: URL
    let referenceLength: Int
}

/// Writes `c.wav` and `r.wav` of the drift package: the signal at session time in `r.wav`, and the
/// same signal at a clock of 1 + 100 ppm from signal second 30 in `c.wav`.
private func writeDriftAudio() throws -> DriftAudio {
    let rate = 48_000
    let length = 300 * rate
    let step = (1 + 100e-6) / Double(rate)
    let referenceLength = Int((30 + Double(length) * step + 30) * Double(rate))
    let folder = FileManager.default.temporaryDirectory.appending(path: "SyncToolDrift-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let voice = DriftSignal(seed: 1, seconds: 30 + 300 * 1.01 + 60)
    try writeWAV(folder.appending(path: "r.wav"), length: referenceLength) {
        voice.samples(start: Double($0.lowerBound) / Double(rate), step: 1 / Double(rate), count: $0.count)
    }
    try writeWAV(folder.appending(path: "c.wav"), length: length) {
        voice.samples(start: 30 + Double($0.lowerBound) * step, step: step, count: $0.count)
    }
    return DriftAudio(folder: folder, referenceLength: referenceLength)
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
