import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// Decision 0077 D10: with a `DriftCause`, the fix moves the clip by the 0076 lag, writes no file,
/// and names the cause.
extension StudioDriftTests {
    /// A clip on a take file, a clip on a rendered file, and a clip with points in 2 cells of 5 (no
    /// fit). Each clip "T" on track "t" plays a copy of the 5 min drift clip.
    @Test func eachCauseMovesTheClipAndWritesNoFile() async throws {
        let voice = DriftSignal(seed: 1, seconds: 30 + 300 * 1.01 + 60)
        let cases: [(String, DriftCause, (DriftPackage) throws -> Void, DriftPackage.Make?)] = [
            ("take file", .takeFile, { try Self.addCopy("take", of: $0, capture: "take") }, nil),
            (
                "rendered file", .renderedFile,
                { drift in
                    let origin = RenderOrigin(
                        source: "c", offset: 0, treatment: Treatment(.noise(.standard)), addedGain: .zero)
                    try Self.addCopy("rendered", of: drift, origin: origin)
                }, nil
            ),
            (
                "no fit", .noFit(.tooFewPoints), { try Self.addCopy("quiet", of: $0) },
                { drift, range in
                    var samples = voice.clip(drift, range)
                    for frame in (60 * drift.rate..<240 * drift.rate).clamped(to: range) {
                        samples[frame - range.lowerBound] = 0
                    }
                    return samples
                }
            ),
        ]
        for (name, cause, edit, clip) in cases {
            let drift = try await DriftPackage.make(seconds: 300, voice: voice, clip: clip)
            try edit(drift)
            try await Self.expectMovedByTheLag("T", drift, cause: cause, name)
        }
    }

    /// A split half of a take has a capture that is not its own ID: it is no take file, and it is
    /// not corrected either.
    @Test func aSplitHalfOfATakeIsNotCorrected() async throws {
        let drift = try await DriftPackage.make(seconds: 300)
        try Self.addCopy("half", of: drift, capture: "take")
        #expect(drift.package.session.files["half"]?.isTakeFile == false)
        try await Self.expectMovedByTheLag("T", drift, cause: .takeFile, "split half")
    }

    /// Clip "T" plays a copy of the 5 min clip at 100 ppm with a drift link to "c" of ratio
    /// 1 - 950e-6: the composed ratio is about 1 - 1050e-6, so the fix writes no file. With a link
    /// of ratio 1 - 800e-6 the composed ratio is about 1 - 900e-6, and the fix resamples "c".
    @Test func aComposedRatioOverTheLimitWritesNoFile() async throws {
        let over = try await DriftPackage.make(seconds: 300)
        try Self.addCopy("first", of: over, drift: try Self.link(ratio: 1 - 950e-6))
        try await Self.expectMovedByTheLag("T", over, cause: .composedRateOutOfRange, "1050 ppm")

        let under = try await DriftPackage.make(seconds: 300)
        let first = try Self.link(ratio: 1 - 800e-6)
        try Self.addCopy("first", of: under, drift: first)
        let studio = try await Self.open(under)
        let fix = try Self.fix(try await studio.correctDrift("T", to: "ref"))
        let link = try #require(studio.session.files[fix.files[0]]?.drift)
        #expect(link.source == "c" && abs(link.ratio.value - (1 - 900e-6)) < 2e-6, "\(link)")
    }

    /// A 10 min line whose lag changes by 0.9 ms (1.5 ppm) is not corrected; 1.1 ms is.
    @Test func theOneMillisecondLine() async throws {
        try await Self.expectMovedByTheLag(
            "C", try await DriftPackage.make(seconds: 600, ppm: 1.5), cause: .underOneMillisecond)
        let drift = try await DriftPackage.make(seconds: 600, ppm: 1.1 / 600 * 1000)
        let studio = try await Self.open(drift)
        _ = try Self.fix(try await studio.correctDrift("C", to: "ref"))
    }

    /// The source of a 12 min clip steps back 30 s at clip minute 5.5, as when the producer cut 30 s
    /// out of the reference: no piece is placed over another.
    @Test func aLagStepDownIsNotCorrected() async throws {
        let drift = try await DriftPackage.make(seconds: 720, pause: -30, at: 330)
        try await Self.expectMovedByTheLag("C", drift, cause: .noFit(.lagStepsBack))
    }

    /// A cancel that comes after the last cancel read of the measure, on a clip with points in 2
    /// cells of 5 (no fit), saves no move.
    @Test func aCancelAfterTheMeasureOfANoFitClipThrows() async throws {
        let voice = DriftSignal(seed: 1, seconds: 30 + 300 * 1.01 + 60)
        let drift = try await DriftPackage.make(
            seconds: 300, voice: voice,
            clip: { drift, range in
                var samples = voice.clip(drift, range)
                for frame in (60 * drift.rate..<240 * drift.rate).clamped(to: range) {
                    samples[frame - range.lowerBound] = 0
                }
                return samples
            })
        let (session, url) = (drift.package.session, drift.package.url)
        try await offMainActor {
            final class Flag { var on = false }
            let cancel = Flag()
            #expect(throws: DriftFailure.cancelled) {
                try driftRequest(
                    "C", to: "ref", within: nil, of: session, in: url, freeBytes: { .max },
                    progress: { if $0 >= 0.49 { cancel.on = true } }, isCancelled: { cancel.on })
            }
            #expect(cancel.on, "the measure did not end")
        }
    }

    /// A 12 min clip with no drift whose source skips 5 s at clip minute 5.5: the fix splits the
    /// clip, and each piece is within 1 ms of its line.
    @Test func aPauseWithNoDriftSplitsTheClip() async throws {
        let drift = try await DriftPackage.make(seconds: 720, ppm: 0, pause: 5, at: 330)
        let studio = try await Self.open(drift)

        let fix = try Self.fix(try await studio.correctDrift("C", to: "ref"))

        #expect(fix.clips.count == 2 && fix.splits.count == 1, "\(fix)")
        for clip in fix.clips { try await Self.expectAligned(clip, in: studio.session, drift, points: nil) }
    }

    /// A session whose transcript did not load (decision 0055) cannot take a drift file: the clip
    /// of 5 min moves by the lag of `syncLag`, and no file is written.
    @Test func anUnloadedTranscriptMovesTheClip() async throws {
        let drift = try await DriftPackage.make(seconds: 300)
        var session = drift.package.session
        session.transcripts[TranscriptID(1)] = Transcript(id: TranscriptID(1), name: "t1", words: nil)
        let url = drift.package.url
        let lag = try await Self.lag(of: "C", in: session, url)
        let start = try #require(session.clip("C")?.clip.start)
        let names = Self.clipsNames(url)

        try await offMainActor { [session] in
            let (moved, report, made) = try driftRequest(
                "C", to: "ref", within: nil, of: session, in: url, freeBytes: { .max })

            #expect(report.outcome == .notCorrected(.transcriptNotLoaded), "\(report.outcome)")
            #expect(report.sync.lag == lag && moved.clip("C")?.clip.start == start + lag)
            #expect(made.isEmpty && Self.clipsNames(url) == names, "a file was written")
        }
    }

    /// A clip of 299 s is not measured; a clip of 300 s is corrected.
    @Test func theFiveMinuteLine() async throws {
        try await Self.expectMovedByTheLag("C", try await DriftPackage.make(seconds: 299), cause: .clipTooShort)
        let drift = try await DriftPackage.make(seconds: 300)
        let studio = try await Self.open(drift)
        _ = try Self.fix(try await studio.correctDrift("C", to: "ref"))
    }
}

extension StudioDriftTests {
    /// The fix of `clip` on the package of `drift` names `cause`, moves the clip by the lag of
    /// `syncLag`, writes no file in `Clips/`, and saves the move as one undo entry.
    static func expectMovedByTheLag(
        _ clip: ClipID, _ drift: DriftPackage, cause: DriftCause, _ name: String = ""
    ) async throws {
        let session = drift.package.session
        let url = drift.package.url
        let lag = try await Self.lag(of: clip, in: session, url)
        let start = try #require(session.clip(clip)?.clip.start)
        let studio = try await Self.open(drift)
        let names = Self.clipsNames(url)

        let report = try await studio.correctDrift(clip, to: "ref")

        #expect(report.outcome == .notCorrected(cause), "\(name): \(report.outcome)")
        #expect(report.sync.lag == lag && studio.session.clip(clip)?.clip.start == start + lag, "\(name)")
        #expect(Self.clipsNames(url) == names, "\(name): a file was written")
        #expect(try Session(contentsOf: url) == studio.session && studio.canUndo, "\(name): the move did not save")
    }

    /// Copies the WAV of clip "C" to `<id>.wav`, adds it to the pool as `id` with `capture`,
    /// `origin`, or `drift`, and puts it on the new track "t" as clip "T" at the place of "C". A
    /// capture gets a session capture record.
    static func addCopy(
        _ id: FileID, of drift: DriftPackage, capture: CaptureID? = nil, origin: RenderOrigin? = nil,
        drift link: DriftOrigin? = nil
    ) throws {
        let clips = drift.package.url.appending(path: clipsFolderName)
        try FileManager.default.copyItem(
            at: clips.appending(path: "c.wav"), to: clips.appending(path: "\(id.rawValue).wav"))
        if let capture {
            try drift.package.session.addCapture(
                Capture(
                    id: capture, deviceUID: "mic", deviceName: "Mic", hostTimeNanos: 0, sampleTime: 0,
                    nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0))
        }
        let length = Frames(drift.length)
        try drift.package.session.addFile(
            AudioFile(
                id: id, path: "\(id.rawValue).wav", layout: .mono, length: length, capture: capture, origin: origin,
                drift: link))
        let start = try #require(drift.package.session.clip("C")?.clip.start)
        try drift.package.addTrack("t", clip: "T", file: id, start: start, offset: 0, length: length)
    }

    /// A drift link to "c" at offset 0 with `ratio` and no added gain.
    static func link(ratio: Double, addedGain: Gain = .zero) throws -> DriftOrigin {
        DriftOrigin(source: "c", offset: 0, ratio: try #require(DriftRatio(ratio)), addedGain: addedGain)
    }
}

extension DriftPackage {
    /// The samples of a frame range of the clip file.
    typealias Make = @Sendable (DriftPackage, Range<Int>) -> [Float]
}
