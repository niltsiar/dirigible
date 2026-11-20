import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Criteria D15 to D17 and the same-package paste of D12 of decision 0077: `Studio.correctDrift` on
/// packages of the drift signal, where clip "C" on track "c" drifts by `DriftPackage.m` against
/// track "ref".
@MainActor
struct StudioDriftTests {
    /// The D6 clip: 10 min at 100 ppm. After the fix, the clip plays one new file with a drift link
    /// to its old file, and a second measure gives 10 points within 1 ms of their median lag.
    @Test func aDriftingClipIsWithinOneMillisecondAfterTheFix() async throws {
        let drift = try DriftPackage(seconds: 600)
        let studio = try await Self.open(drift)

        let report = try await studio.correctDrift("C", to: "ref")

        let fix = try Self.fix(report)
        #expect(fix.splits.isEmpty && fix.clips == ["C"] && fix.files.count == 1, "\(fix)")
        #expect(abs(fix.slope - drift.m) * 1e6 < 0.1, "rate \(fix.slope * 1e6) ppm")
        let file = try #require(studio.session.files[fix.files[0]])
        #expect(file.path == "c drift.wav" && file.drift?.source == "c", "\(file)")
        #expect(studio.session.clip("C")?.clip.file == file.id)
        try Self.expectAligned("C", in: studio, drift, points: 10)
        #expect(try Session(contentsOf: drift.package.url) == studio.session, "the fix did not save")
    }

    @Test func aSecondFixFindsNoDrift() async throws {
        let drift = try DriftPackage(seconds: 600)
        let studio = try await Self.open(drift)
        _ = try Self.fix(try await studio.correctDrift("C", to: "ref"))
        let names = Self.clipsNames(drift.package.url)

        let second = try await studio.correctDrift("C", to: "ref")

        #expect(second.outcome == .notCorrected(.underOneMillisecond), "\(second.outcome)")
        #expect(Self.clipsNames(drift.package.url) == names, "a second fix wrote a file")
    }

    @Test func undoPutsBackTheDriftingClip() async throws {
        let drift = try DriftPackage(seconds: 600)
        let studio = try await Self.open(drift)
        let before = studio.session

        _ = try Self.fix(try await studio.correctDrift("C", to: "ref"))
        #expect(studio.session != before)
        try studio.undo()

        #expect(studio.session == before && !studio.canUndo, "the fix is more than one undo step")
    }

    /// A 44.1 kHz original of the drift clip, imported into the 48 kHz session, gets the same bars.
    @Test func anOriginalAt44100IsCorrected() async throws {
        let voice = DriftSignal(seed: 1, seconds: 30 + 600 * 1.01 + 60)
        let drift = try DriftPackage(seconds: 600, voice: voice)
        let original = drift.package.folder.url.appending(path: "guest.wav")
        let step = (1 + drift.m) / 44_100
        try writeWAV(original, rate: 44_100, length: 600 * 44_100) { range in
            voice.samples(start: 30 + Double(range.lowerBound) * step, step: step, count: range.count)
        }
        let studio = try await Self.open(drift)
        let target = ImportTarget(track: nil, start: Frames(30 * drift.rate - drift.offset), clip: "G")
        let imported = try await studio.importAudio(original, to: target, level: false) { _ in }

        let fix = try Self.fix(try await studio.correctDrift(imported, to: "ref"))

        #expect(abs(fix.slope - drift.m) * 1e6 < 0.1, "rate \(fix.slope * 1e6) ppm")
        try Self.expectAligned(imported, in: studio, drift, points: 10)
    }

    /// The D8 clip: 12 min at 100 ppm, whose source skips 20 s at clip minute 5.5. Each piece plays
    /// its own new file and is within 1 ms of its line.
    @Test func aPausedRecordingGivesTwoAlignedClips() async throws {
        let drift = try DriftPackage(seconds: 720, pause: 20, at: 330)
        let studio = try await Self.open(drift)

        let fix = try Self.fix(try await studio.correctDrift("C", to: "ref"))

        #expect(fix.clips.count == 2 && Set(fix.files).count == 2 && fix.splits.count == 1, "\(fix)")
        let pause = try #require(fix.splits.first).pause - 20 * Double(drift.rate)
        #expect(abs(pause) <= Double(drift.rate) / 1000, "the pause is \(pause) frames off")
        for (clip, file) in zip(fix.clips, fix.files) {
            #expect(studio.session.clip(clip)?.clip.file == file)
            try Self.expectAligned(clip, in: studio, drift, points: nil)
        }
    }

    /// A cancel at the first cancel read after the renames removes the new file and saves nothing.
    @Test func aCancelLeavesNoNewFile() async throws {
        let drift = try DriftPackage(seconds: 300)
        let studio = try await Self.open(drift)
        let url = drift.package.url
        let renamed = url.appending(path: "\(clipsFolderName)/c drift.wav")
        let gate = Gate(limit: Gate.openLimit)
        studio.environment.importStep = {
            if FileManager.default.fileExists(atPath: renamed.path) { gate.waitOnce() }
        }
        let (bytes, names) = (try Self.sessionBytes(url), Self.clipsNames(url))

        let fixing = Task { try await studio.correctDrift("C", to: "ref") }
        await gate.entered()
        #expect(FileManager.default.fileExists(atPath: renamed.path), "the renames ran")
        studio.cancelImport()
        gate.open()

        await #expect(throws: StudioError.syncCancelled) { try await fixing.value }
        #expect(Self.clipsNames(url) == names, "the cancel left a file: \(Self.clipsNames(url))")
        #expect(try Self.sessionBytes(url) == bytes && !studio.canUndo, "a cancelled fix saved")
    }

    /// During the job a move and an undo throw `.busy`, and the job goes on to its fix.
    @Test func noEditDuringTheFix() async throws {
        let drift = try DriftPackage(seconds: 300)
        let studio = try await Self.open(drift)
        let gate = Gate(limit: Gate.openLimit)
        studio.environment.importStep = { gate.waitOnce() }
        let start = studio.session.clip("R")?.clip.start

        let fixing = Task { try await studio.correctDrift("C", to: "ref") }
        await gate.entered()
        #expect(throws: StudioError.busy) {
            try studio.amend { session throws(SessionError) in try session.nudge(["R"], by: 48_000) }
        }
        #expect(throws: StudioError.busy) { try studio.undo() }
        gate.open()

        _ = try Self.fix(try await fixing.value)
        #expect(studio.session.clip("R")?.clip.start == start, "the move ran")
    }

    /// The P6 tone: 0.25 s of a 12 kHz tone at phase pi/4 with samples at full scale (true peak
    /// +3.01 dBFS) in a 6 min clip at 100 ppm. After the fix, the tone plays within 0.1 dB of its
    /// level before.
    @Test func aFullScaleClipKeepsItsLevel() async throws {
        let (drift, tone) = try Self.tonePackage(seconds: 360, ppm: 100, amplitude: Float(2).squareRoot())
        let studio = try await Self.open(drift)
        let before = try Self.toneLevel(of: "C", in: studio, drift, tone: tone)

        _ = try Self.fix(try await studio.correctDrift("C", to: "ref"))

        let after = try Self.toneLevel(of: "C", in: studio, drift, tone: tone)
        #expect(abs(after - before) < 0.1, "the tone plays at \(after) dB, before \(before) dB")
    }
}

extension StudioDriftTests {
    /// Writes the session of `drift` and opens its studio.
    static func open(_ drift: DriftPackage) async throws -> Studio {
        try drift.package.session.write(to: drift.package.url)
        return try await Studio.open(drift.package.url)
    }

    /// The fix of a report that corrected the drift.
    nonisolated static func fix(_ report: DriftSyncReport) throws -> DriftFix {
        let fix: DriftFix? = if case .corrected(let fix) = report.outcome { fix } else { nil }
        return try #require(fix, "the drift was not corrected: \(report.outcome)")
    }

    static func clipsNames(_ package: URL) -> [String] {
        let names = try? FileManager.default.contentsOfDirectory(atPath: package.appending(path: clipsFolderName).path)
        return (names ?? []).sorted()
    }

    static func sessionBytes(_ package: URL) throws -> Data {
        try Data(contentsOf: package.appending(path: "session.xml"))
    }

    /// A second measure of `clip` against "ref": `points` points (any count when nil), each within
    /// 1 ms of their median lag, and a fit rate under 1 ppm.
    static func expectAligned(_ clip: ClipID, in studio: Studio, _ drift: DriftPackage, points: Int?) throws {
        let session = studio.session
        let measured = try driftMeasure(
            of: clip, to: "ref", in: session, package: drift.package.url, span: session.syncSpan(clip, to: "ref")
        ).points
        if let points { #expect(measured.count == points, "\(clip): \(measured.count) points") }
        let lags = measured.map(\.lag).sorted()
        let median = lags[lags.count / 2]
        for point in measured {
            #expect(
                abs(point.lag - median) <= Double(drift.rate) / 1000,
                "\(clip): the point at \(point.clipFrame) is \(point.lag - median) frames off")
        }
        let fit = try DriftFit(points: measured, sampleRate: Double(drift.rate))
        #expect(abs(fit.slope) < 1e-6, "\(clip): rate \(fit.slope * 1e6) ppm after the fix")
    }

    /// A package of the drift signal with a 12 kHz tone at phase pi/4 and `amplitude` in clip
    /// seconds 100 to 100.25, where the voice is silent. Returns the package and the tone frames.
    nonisolated static func tonePackage(
        seconds: Double, ppm: Double, amplitude: Float
    ) throws -> (DriftPackage, Range<Int>) {
        var voice = DriftSignal(seed: 1, seconds: 30 + seconds * 1.01 + 60)
        let source = { (second: Double) in 30 + second * (1 + ppm * 1e-6) }
        voice.set(speech: false, in: source(99.5)..<source(100.75))
        let tone = 100 * 48_000..<Int(100.25 * 48_000)
        let drift = try DriftPackage(
            seconds: seconds, ppm: ppm, voice: voice,
            clip: { drift, range in
                var samples = voice.clip(drift, range)
                for frame in tone.clamped(to: range) {
                    let phase = Float.pi / 2 * Float(frame % 4) + Float.pi / 4
                    samples[frame - range.lowerBound] = amplitude * sin(phase)
                }
                return samples
            })
        return (drift, tone)
    }

    /// The level in dB that `clip` plays in the inner 0.15 s of the tone of `tonePackage`: the RMS
    /// of its file there plus its gain. The tone is in source frames `tone` of the drift source.
    static func toneLevel(of clip: ClipID, in studio: Studio, _ drift: DriftPackage, tone: Range<Int>) throws -> Double
    {
        let played = try #require(studio.session.clip(clip)?.clip)
        let file = try #require(studio.session.files[played.file])
        let inner = Double(tone.lowerBound + 2_400)..<Double(tone.upperBound - 2_400)
        let map = { (frame: Double) in
            Int((file.drift.map { (frame - Double($0.offset.count)) / $0.ratio.value } ?? frame).rounded())
        }
        let samples = try readAudio(drift.package.url.appending(path: "\(clipsFolderName)/\(file.path)")).samples
        let frames = samples[map(inner.lowerBound)..<map(inner.upperBound)]
        let mean = frames.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(frames.count)
        return 10 * log10(mean) + played.gain.dB
    }
}

/// Writes a mono 24-bit WAV at `rate` of `length` frames in blocks from `samples`.
func writeWAV(_ url: URL, rate: Int, length: Int, samples: (Range<Int>) -> [Float]) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1))
    let block = 1 << 20
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)))
    let writer = try ClipWriter(url: url, file: url.lastPathComponent, format: format)
    for first in stride(from: 0, to: length, by: block) {
        let frames = samples(first..<min(first + block, length))
        buffer.frameLength = AVAudioFrameCount(frames.count)
        buffer.floatChannelData![0].update(from: frames, count: frames.count)
        try writer.write(buffer)
    }
    try writer.close()
}
