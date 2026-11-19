import Accelerate
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A package at 48 kHz: track "ref" holds clip "R" (100 s, file "r") whose audio is another
/// speech-like signal with the 30 s clip audio at half gain from 30 s; track "c" holds clip "C"
/// (file "c", that clip audio) at `start`, 35 s by default, so the lag is -5 s.
func syncPackage(start: Frames = 1_680_000, reference other: [Float]? = nil) throws -> MixPackage {
    let clip = SpeechLike(seconds: 30, rate: 48_000, seed: 1).frames(0..<1_440_000)
    let package = try MixPackage()
    let audio = other ?? reference(seconds: 100, rate: 48_000, holding: clip.map { 0.5 * $0 }, at: 1_440_000)
    try package.addFile("r", channels: [audio])
    try package.addTrack("ref", clip: "R", file: "r", start: 0, offset: 0, length: Frames(audio.count))
    try package.addFile("c", channels: [clip])
    try package.addTrack("c", clip: "C", file: "c", start: start, offset: 0, length: 1_440_000)
    return package
}

extension MixPackage {
    /// Adds the pool file `id` of one second and removes its WAV, so `checkMedia` finds it missing.
    func addMissingFile(_ id: FileID) throws {
        try addFile(id, channels: [[Float](repeating: 0.1, count: 48_000)])
        try FileManager.default.removeItem(at: url.appending(path: "\(clipsFolderName)/\(id.rawValue).wav"))
    }

    /// `syncLag` of clip "C" to track "ref" in the span of `within` (nil: the default).
    func syncC(
        within: Frames? = nil, progress: (Double) -> Void = { _ in }, open: @escaping MediaOpen = openMedia,
        makeSetup: DFTSetupMake = vDSP_DFT_zrop_CreateSetup
    ) throws(SyncFailure) -> SyncResult {
        let span: Range<Frames>
        do { span = try session.syncSpan("C", to: "ref", within: within) } catch {
            Issue.record("syncSpan: \(error)")
            throw .cancelled
        }
        return try syncLag(
            of: "C", to: "ref", in: session, package: url, span: span, progress: progress, isCancelled: { false },
            open: open, makeSetup: makeSetup)
    }
}

/// Criteria C3 and C6 of decision 0076: the shared read `syncLag` on packages, with no `Studio`.
struct SyncLagTests {
    @Test func aCopyOnTheReferenceGivesItsLag() throws {
        let result = try syncPackage().syncC()
        #expect(result.lag == -240_000)
        #expect((0.99...1.01).contains(result.score.peak), "\(result.score)")
        #expect(result.spread == nil, "a 30 s clip has one excerpt")
    }

    @Test func anUnrelatedReferenceIsNoMatch() throws {
        let unrelated = SpeechLike(seconds: 100, rate: 48_000, seed: 7).frames(0..<4_800_000)
        #expect {
            try syncPackage(reference: unrelated).syncC()
        } throws: { error in
            guard case SyncFailure.noMatch(let best) = error else { return false }
            return !best.isMatch && best.peak < 0.2
        }
    }

    /// A missing clip file, a missing or unreadable reference file, and a missing reference file
    /// at the span end each refuse with the file and the fault before the stream reads a frame.
    @Test func aFileFaultIsRefusedBeforeTheRead() throws {
        var reads = 0
        let missingClip = try syncPackage()
        try FileManager.default.removeItem(at: missingClip.url.appending(path: "\(clipsFolderName)/c.wav"))
        #expect(throws: SyncFailure.file("c", .missing)) { try missingClip.syncC(progress: { _ in reads += 1 }) }

        let unreadable = try syncPackage()
        try Data("not audio".utf8).write(to: unreadable.url.appending(path: "\(clipsFolderName)/r.wav"))
        #expect(throws: SyncFailure.file("r", .unreadable)) { try unreadable.syncC(progress: { _ in reads += 1 }) }

        let atEnd = try syncPackage()
        try atEnd.session.trim("R", to: 0..<4_752_000)
        try atEnd.addMissingFile("end")
        try atEnd.session.place(Clip(id: "E", file: "end", start: 4_752_000, offset: 0, length: 48_000), on: "ref")
        #expect(try atEnd.session.syncSpan("C", to: "ref").upperBound == 4_800_000)
        #expect(throws: SyncFailure.file("end", .missing)) { try atEnd.syncC(progress: { _ in reads += 1 }) }
        #expect(reads == 0, "a refusal read \(reads) chunks")
    }

    /// Missing files of clips that the sync does not read: on a third track in the span, on the
    /// reference track outside the span, and of another clip in the span on the track of "C".
    @Test func anUnrelatedMissingFileDoesNotBlock() throws {
        let package = try syncPackage()
        for id: FileID in ["third", "outside", "neighbor"] { try package.addMissingFile(id) }
        try package.session.addTrack("x", name: "x", layout: .mono)
        try package.session.place(Clip(id: "X", file: "third", start: 2_000_000, offset: 0, length: 48_000), on: "x")
        try package.session.trim("R", to: 0..<4_000_000)
        try package.session.place(
            Clip(id: "O", file: "outside", start: 4_752_000, offset: 0, length: 48_000), on: "ref")
        try package.session.place(
            Clip(id: "N", file: "neighbor", start: 3_360_000, offset: 0, length: 48_000), on: "c")
        let within = Frames(480_000)
        #expect(try package.session.syncSpan("C", to: "ref", within: within) == 1_200_000..<3_600_000)
        #expect(try package.syncC(within: within).lag == -240_000)
    }

    /// The read ignores mute, so a muted reference track with a missing file is refused.
    @Test func aMutedReferenceIsChecked() throws {
        let package = try syncPackage()
        try package.session.setMuted(true, tracks: ["ref"])
        try FileManager.default.removeItem(at: package.url.appending(path: "\(clipsFolderName)/r.wav"))
        #expect(throws: SyncFailure.file("r", .missing)) { try package.syncC() }
    }

    /// A spread over 20 ms is notable and 20 ms is not, at 48 kHz and at 44.1 kHz.
    @Test func aSpreadOver20MillisecondsIsNotable() {
        for (rate, at20) in [(48_000, 960), (44_100, 882)] {
            #expect(!SyncResult.spreadIsNotable(Frames(at20), rate: rate), "\(at20) frames at \(rate) Hz")
            #expect(SyncResult.spreadIsNotable(Frames(at20 + 1), rate: rate), "\(at20 + 1) frames at \(rate) Hz")
            #expect(!SyncResult.spreadIsNotable(.zero, rate: rate))
        }
    }

    /// No memory for a DFT setup of the coarse step, forward or inverse, is a read failure with ENOMEM.
    @Test func noMemoryForTheCoarseSetupIsAReadFailure() throws {
        let package = try syncPackage()
        let inverseOnly: DFTSetupMake = { previous, length, direction in
            direction == .INVERSE ? nil : vDSP_DFT_zrop_CreateSetup(previous, length, direction)
        }
        for make in [{ _, _, _ in nil }, inverseOnly] as [DFTSetupMake] {
            #expect(throws: SyncFailure.read(POSIXError(.ENOMEM))) { try package.syncC(makeSetup: make) }
        }
        #expect(try package.syncC().lag == -240_000, "the package does not sync with a real setup")
    }

    /// No free descriptor at the open is a read failure with its errno, not a file fault.
    @Test func noFreeDescriptorIsAReadFailure() throws {
        let package = try syncPackage()
        #expect(throws: SyncFailure.read(POSIXError(.EMFILE))) {
            try package.syncC(open: { _, _, _ throws(POSIXError) in throw POSIXError(.EMFILE) })
        }
    }
}
