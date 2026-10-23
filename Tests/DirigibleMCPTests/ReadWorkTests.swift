import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// The argument rules and the texts of `silences`, `nearest_pause`, and `meter` (decision 0062).
/// The package of `LivePackage.addTone` has the 3 s tone clip `c1` on the mono track `t1`, so its
/// session end is frame 144,000.
struct ReadWorkTests {
    static let refusal =
        "file tone \"tone.wav\" is missing; its clips would read as silence, so the read gives no silence or "
        + "pause. Restore the file, or read a range or tracks without it."

    static func silences(
        from: Int = 0, to: Int? = nil, tracks: [String] = [], threshold: Double? = nil, minLength: Int? = nil
    ) throws -> ReadWork {
        try ReadWork.silences(from: from, to: to, tracks: tracks, threshold: threshold, minLength: minLength).get()
    }

    static func pause(at: Int, window: Int? = nil, threshold: Double? = nil, minLength: Int? = nil) throws -> ReadWork {
        try ReadWork.nearestPause(at: at, window: window, tracks: [], threshold: threshold, minLength: minLength).get()
    }

    static func meter(from: Int = 0, to: Int? = nil, step: Int? = nil) throws -> ReadWork {
        try ReadWork.meter(from: from, to: to, tracks: [], step: step).get()
    }

    /// The tone package, with its WAV removed when `missing`.
    static func tone(missing: Bool = false) throws -> (LivePackage, Session) {
        let package = try LivePackage()
        try package.addTone()
        if missing { try FileManager.default.removeItem(at: package.url.appending(path: "Clips/tone.wav")) }
        return (package, try Session(contentsOf: package.url))
    }

    @Test func silencesTextCapsAtOneThousandLines() {
        let silences = (0..<1001).map { Frames($0 * 4800)..<Frames($0 * 4800 + 2400) }
        let lines = ReadWork.silencesLines(silences, spelling: .tool)
        #expect(lines.count == 1001)
        #expect(lines.first == "0\t2400" && lines[999] == "4795200\t4797600", "\(lines.prefix(2)), \(lines[999])")
        #expect(lines.last == "1 more silences: give a shorter range or a longer min_length.")
        #expect(ReadWork.silencesLines(silences, spelling: .cli).last?.hasSuffix("a longer --min-length.") == true)
        let thousand = ReadWork.silencesLines(Array(silences.prefix(1000)), spelling: .tool)
        #expect(thousand.count == 1000 && thousand.last == "4795200\t4797600", "1000 silences have no more line")
    }

    @Test func noSilenceGivesOneLine() {
        #expect(ReadWork.silencesLines([], spelling: .tool) == ["No silence."])
    }

    @Test func pauseAndNoPauseLines() {
        #expect(ReadWork.pauseLine(.pause(48_000..<72_000, cut: 60_000)) == "pause\t48000\t72000\t60000")
        let quiet = WindowLevel(meanSquare: 0.001, peak: 0.1)
        #expect(ReadWork.pauseLine(.noPause(cut: 1200, level: quiet)) == "no pause\t1200\t-30.0 dBFS")
    }

    @Test func meterLineGivesNoneAndSignedValues() {
        let loud = MixMeasure(
            integrated: LUFS(value: -15.54), loudnessRange: 6.36, maxMomentary: LUFS(value: -9.0),
            maxShortTerm: LUFS(value: -11.26), truePeak: 4.6, samplePeak: 3.04)
        #expect(
            ReadWork.meterLine(loud, length: 5_760_000, rate: 48_000)
                == "heard stereo mix: loudness -15.5 LUFS, range 6.4 LU, max momentary -9.0 LUFS, max short-term "
                + "-11.3 LUFS, true peak +4.6 dBTP, peak +3.0 dBFS")
        let silence = MixMeasure(
            integrated: nil, loudnessRange: nil, maxMomentary: nil, maxShortTerm: nil, truePeak: nil, samplePeak: nil)
        #expect(
            ReadWork.meterLine(silence, length: 5_760_000, rate: 48_000)
                == "heard stereo mix: loudness none, range none, max momentary none, max short-term none, true peak "
                + "none, peak none")
    }

    /// EBU R 128 s1: the loudness range does not apply to a range of 2 min or less.
    @Test func theRangeOfAShortRangeIsNone() {
        let measure = MixMeasure(
            integrated: LUFS(value: -20), loudnessRange: 6.36, maxMomentary: LUFS(value: -18),
            maxShortTerm: LUFS(value: -19), truePeak: -3, samplePeak: -3)
        #expect(ReadWork.meterLine(measure, length: 5_755_200, rate: 48_000).contains(", range none (under 2 min),"))
        #expect(ReadWork.meterLine(measure, length: 5_760_000, rate: 48_000).contains(", range 6.4 LU,"))
    }

    /// The media check before the scan counts the muted track, so the refusal comes with no read.
    @Test func aFaultRefusesSilencesAndPause() throws {
        var (package, session) = try Self.tone(missing: true)
        try session.setMuted(true, tracks: ["t1"])
        for work in [try Self.silences(), try Self.pause(at: 72_000)] {
            let progress = Progress()
            #expect(throws: ReadFailure.refused(Self.refusal)) {
                try work.read(session, package: package.url, progress: progress.add)
            }
            #expect(progress.values.isEmpty, "the refusal came after a read: \(progress.values)")
        }
    }

    @Test func meterPutsTheFaultLinesFirst() throws {
        let (package, session) = try Self.tone(missing: true)
        let output = try Self.meter().read(session, package: package.url)
        let warning = "Warning: file tone \"tone.wav\" is missing; its clips render as silence."
        #expect(output.stderr == [warning], "\(output.stderr)")
        #expect(
            output.text
                == warning + "\nheard stereo mix: loudness none, range none (under 2 min), max momentary none, max "
                + "short-term none, true peak none, peak none", "\(output.text)")
    }

    /// `meter` warns as a stereo export of the range does: the soloed empty track `t2` leaves out
    /// the tone track, and a muted track that the call names leaves nothing heard.
    @Test func meterWarnsOfTheTracksThatAreNotHeard() throws {
        var (package, session) = try Self.tone()
        try session.setSoloed(true, tracks: ["t2"])
        let soloed = try Self.meter().read(session, package: package.url)
        #expect(soloed.stderr == ["Warning: 1 track is muted or not soloed and is not in the export."], "\(soloed)")
        try session.setSoloed(false, tracks: ["t2"])
        try session.setMuted(true, tracks: ["t1"])
        let muted = try ReadWork.meter(from: 0, to: nil, tracks: ["t1"], step: nil).get()
            .read(session, package: package.url)
        #expect(muted.stderr == ["Warning: no track is heard; the file is silent."], "\(muted)")
    }

    @Test func aStepThatIsNotAWholeWindowIsRefused() throws {
        let (package, session) = try Self.tone()
        #expect(throws: ReadFailure.usage("step must be a multiple of the 50 ms window, 2400 frames.")) {
            try Self.meter(step: 1000).read(session, package: package.url)
        }
        let lines = try Self.meter(step: 4800).read(session, package: package.url).stdout
        #expect(lines.count == 31 && lines[1].hasPrefix("0\t") && lines[30].hasPrefix("139200\t"), "\(lines)")
    }

    /// The count check runs before the scan: no progress value comes. 1000 lines read.
    @Test func aStepCountOverOneThousandIsRefusedBeforeTheRead() throws {
        let package = try LivePackage()
        var session = try Session(contentsOf: package.url)
        try session.addFile(AudioFile(id: "long", path: "long.wav", layout: .mono, length: 2_402_400))
        try session.place(Clip(id: "c1", file: "long", start: 0, offset: 0, length: 2_402_400), on: "t1")
        let progress = Progress()
        #expect(
            throws: ReadFailure.usage("step gives 1001 lines, more than 1000. Give a longer step or a shorter range.")
        ) {
            try Self.meter(step: 2400).read(session, package: package.url, progress: progress.add)
        }
        #expect(progress.values.isEmpty, "the refusal came after a read: \(progress.values)")
        let lines = try Self.meter(to: 2_400_000, step: 2400).read(session, package: package.url).stdout
        #expect(lines.count == 1001, "\(lines.count) lines")
    }

    /// The rules of C8. A bad value is a usage error (CLI exit 64); an unknown track is a refusal
    /// (CLI exit 2).
    @Test func theArgumentRules() throws {
        let range = "from is a frame in 0...2^40, and to is more than from."
        #expect(ReadWork.silences(from: -1, to: nil, tracks: [], threshold: nil, minLength: nil).refusal == range)
        #expect(ReadWork.meter(from: 10, to: 10, tracks: [], step: nil).refusal == range)
        let level = "threshold is a dB value under 0 and not under -96."
        for value in [0, -96.5] {
            #expect(ReadWork.silences(from: 0, to: nil, tracks: [], threshold: value, minLength: nil).refusal == level)
        }
        #expect(ReadWork.silences(from: 0, to: nil, tracks: [], threshold: -96, minLength: nil).refusal == nil)
        #expect(
            ReadWork.nearestPause(at: 0, window: nil, tracks: [], threshold: nil, minLength: -1).refusal
                == "min_length is a length in frames in 0...2^40.")
        #expect(
            ReadWork.nearestPause(at: 0, window: 0, tracks: [], threshold: nil, minLength: nil).refusal
                == "window is a length in frames in 1...2^40.")
        #expect(
            ReadWork.nearestPause(at: -1, window: nil, tracks: [], threshold: nil, minLength: nil).refusal
                == "at is a frame in 0...2^40.")
        #expect(
            ReadWork.meter(from: 0, to: nil, tracks: [], step: 0, spelling: .cli).refusal
                == "--step is a length in frames in 1...2^40.")

        let (package, session) = try Self.tone()
        #expect(throws: ReadFailure.usage("from must be before the session end, frame 144000.")) {
            try Self.silences(from: 144_000).read(session, package: package.url)
        }
        #expect(throws: ReadFailure.usage("at must be before the session end, frame 144000.")) {
            try Self.pause(at: 144_000).read(session, package: package.url)
        }
        #expect(throws: ReadFailure.refused("no track \"t9\".")) {
            try Self.silences(tracks: ["t9"]).read(session, package: package.url)
        }
        // A to past the end stops at the end: the step lines end at frame 144,000 either way.
        let past = try Self.meter(to: 1_000_000, step: 48_000).read(session, package: package.url)
        let end = try Self.meter(to: 144_000, step: 48_000).read(session, package: package.url)
        #expect(past == end && past.stdout.count == 4, "\(past.stdout)")
    }
}

/// The progress values of a read, from any thread.
private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Double] = []
    var values: [Double] { lock.withLock { list } }
    func add(_ value: Double) { lock.withLock { list.append(value) } }
}

extension Result where Failure == ToolError {
    /// The text of a refused parse, or nil.
    fileprivate var refusal: String? {
        guard case .failure(let error) = self else { return nil }
        return error.message
    }
}
