import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The finalize fault rule of decision 0012 (criteria 19, 20, 21): a fault of one segment leaves
/// that segment unplaced and the take ends; only a fault that can go away throws.
struct FinalizeFaultTests {
    let package: TakePackage

    /// A take with two tracks, `t1` and `t2`, and a 2.0 s segment on each.
    init() throws {
        package = try TakePackage(tracks: [("t1", .mono), ("t2", .mono)])
        try package.segment(arm: 1, samples: sine(seconds: 2, rate: 48_000))
        try package.segment(arm: 2, samples: sine(seconds: 2, rate: 48_000, frequency: 500))
    }

    func file(_ name: String) -> URL { package.capture.appending(path: name) }

    enum Fault: String, CaseIterable, CustomTestStringConvertible {
        case badMagic, randomCAF, emptyCAF, rateNotTheHeaderRate, clipIDInUse
        var testDescription: String { rawValue }
    }

    func apply(_ fault: Fault) throws {
        switch fault {
        case .badMagic:
            let handle = try FileHandle(forWritingTo: file("take1-1-1.sidecar"))
            try handle.write(contentsOf: Data("XXXXXXXX".utf8))
            try handle.close()
        case .randomCAF:
            var random = SeededGenerator(seed: 7)
            try Data((0..<10_000).map { _ in UInt8.random(in: 0...255, using: &random) }).write(
                to: file("take1-1-1.caf"))
        case .emptyCAF:
            // AVAudioFile gives 'wht?', the open code of a real I/O fault too.
            try Data().write(to: file("take1-1-1.caf"))
        case .rateNotTheHeaderRate:
            // The CAF is at 44.1 kHz; the sidecar says 48 kHz.
            let sidecar = try Data(contentsOf: file("take1-1-1.sidecar"))
            try package.segment(
                arm: 1, header: TakePackage.header(rate: 44_100), samples: sine(seconds: 2, rate: 44_100))
            try sidecar.write(to: file("take1-1-1.sidecar"))
        case .clipIDInUse:
            var session = try package.read()
            try session.addFile(AudioFile(id: "user", path: "user.wav", layout: .mono, length: 1_000))
            try session.place(Clip(id: "take1-1-1", file: "user", start: 0, offset: 0, length: 1_000), on: "t2")
            try session.write(to: package.url)
        }
    }

    @Test(arguments: Fault.allCases)
    func aFaultOfOneSegmentLeavesItUnplacedAndPlacesTheOther(fault: Fault) throws {
        try apply(fault)

        let session = try finalizeTake(of: package.read(), in: package.url)

        #expect(session.recording == nil)
        #expect(session.track("t2")?.clips.contains { $0.id == "take1-2-1" } == true)
        #expect(session.captures["take1-1-1"] == nil)
        #expect(session.files["take1-1-1"] == nil)
        #expect(session.track("t1")?.clips.isEmpty == true)
        #expect(unplacedSegments(segmentsWithAudio(in: package.url), session: session).map(\.stem) == ["take1-1-1"])
        // Also after a conversion (a session refusal): no WAV and
        // no temporary file of the unplaced segment stays in `Clips/`.
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: package.url.appending(path: "Clips").path)
                == ["take1-2-1.wav"])
    }

    /// Decision 0024: a sidecar of a newer version is a fault of its segment. The take ends, the
    /// other segment is placed, and the sidecar and the CAF keep their bytes. "Leave unreadable"
    /// does not change it, and without it the take does not stay pending.
    @Test(arguments: [false, true])
    func aNewerSidecarEndsTheTakeAndStaysUnplaced(leavingUnreadable: Bool) throws {
        try setMagicDigit(file("take1-1-1.sidecar"), "2")
        let (sidecar, caf) = (
            try Data(contentsOf: file("take1-1-1.sidecar")), try Data(contentsOf: file("take1-1-1.caf"))
        )

        let session = try finalizeTake(of: package.read(), in: package.url, leavingUnreadable: leavingUnreadable)

        #expect(session.recording == nil)
        #expect(session.track("t2")?.clips.map(\.id) == ["take1-2-1"])
        #expect(session.captures["take1-1-1"] == nil)
        #expect(session.track("t1")?.clips.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: file("take1.anchor").path))
        #expect(!FileManager.default.fileExists(atPath: package.url.appending(path: "Clips/take1-1-1.wav").path))
        #expect(try Data(contentsOf: file("take1-1-1.sidecar")) == sidecar)
        #expect(try Data(contentsOf: file("take1-1-1.caf")) == caf)
        #expect(unplacedSegments(segmentsWithAudio(in: package.url), session: session).map(\.stem) == ["take1-1-1"])
        #expect(newerSidecarVersion(of: SegmentName(stem: "take1-1-1")!, in: package.url) == 2)
        #expect(newerSidecarVersion(of: SegmentName(stem: "take1-2-1")!, in: package.url) == nil)
    }

    @Test func withNoFaultBothSegmentsArePlaced() throws {
        let session = try finalizeTake(of: package.read(), in: package.url)

        #expect(session.track("t1")?.clips.map(\.id) == ["take1-1-1"])
        #expect(session.track("t2")?.clips.map(\.id) == ["take1-2-1"])
        #expect(unplacedSegments(segmentsWithAudio(in: package.url), session: session) == [])
    }

    @Test func aCAFThatDoesNotOpenThrowsAndPlacesNothing() throws {
        chmod(file("take1-1-1.caf").path, 0o000)
        defer { chmod(file("take1-1-1.caf").path, 0o644) }

        #expect(
            throws: FinalizeError.segmentUnreadable(
                SegmentName(stem: "take1-1-1")!, file: "Capture/take1-1-1.caf", errno: EACCES)
        ) {
            try finalizeTake(of: package.read(), in: package.url)
        }
    }

    @Test func aClipsFolderThatIsReadOnlyThrows() throws {
        let clips = package.url.appending(path: "Clips")
        chmod(clips.path, 0o500)
        defer { chmod(clips.path, 0o755) }

        let error = #expect(throws: FinalizeError.self) { try finalizeTake(of: package.read(), in: package.url) }
        guard case .writeFailed(let file, _) = error else {
            Issue.record("Expected writeFailed, got \(String(describing: error))")
            return
        }
        #expect(file == "Clips/take1-1-1.wav")
    }

    /// Finalize flushes each WAV and then `Clips/` before the save, so `session.xml` never points
    /// to a WAV that a power loss can lose. Without read access to `Clips/`, the WAVs are made and
    /// read back, and only the folder flush fails: a take-wide fault, so the take stays pending.
    @Test func aClipsFolderThatCannotBeFlushedKeepsTheTakePending() async throws {
        let clips = package.url.appending(path: "Clips")
        chmod(clips.path, 0o300)
        defer { chmod(clips.path, 0o755) }

        let lock = try PackageLock(package.url)
        let outcome = await completeTake(of: try package.read(), lock: lock)

        #expect(outcome.error == .finalize(.writeFailed(file: "Clips", status: EACCES)))
        #expect(try package.read().recording?.take == 1)
    }

    @Test func anErrnoInTheMiddleOfACAFReadThrows() throws {
        let fault = ReadFault(stem: "take1-1-1", block: 1) { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }

        #expect(
            throws: FinalizeError.segmentUnreadable(
                SegmentName(stem: "take1-1-1")!, file: "Capture/take1-1-1.caf", errno: EIO)
        ) {
            try finalizeTake(of: package.read(), in: package.url, readFault: fault)
        }
    }

    /// The leave mode of decision 0021: the same fault leaves only that segment unplaced.
    @Test func theLeaveModePlacesTheOtherSegmentAfterAnErrnoInACAFRead() throws {
        let fault = ReadFault(stem: "take1-1-1", block: 1) { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }

        let session = try finalizeTake(of: package.read(), in: package.url, leavingUnreadable: true, readFault: fault)

        #expect(session.track("t1")?.clips.isEmpty == true)
        #expect(session.track("t2")?.clips.map(\.id) == ["take1-2-1"])
        #expect(session.recording == nil)
        #expect(!FileManager.default.fileExists(atPath: package.url.appending(path: "Clips/.take1-1-1.wav.tmp").path))
    }

    /// The shape of a real I/O fault (probe 2026-09-24): AVAudioFile -40 with no errno. Here every
    /// byte of the CAF reads with POSIX, so it is a bad file, and only that segment stays unplaced.
    @Test func aReadErrorWithNoErrnoOnAFileThatReadsLeavesTheSegmentUnplaced() throws {
        let fault = ReadFault(stem: "take1-1-1", block: 1) {
            throw NSError(domain: "com.apple.coreaudio.avfaudio", code: -40)
        }

        let session = try finalizeTake(of: package.read(), in: package.url, readFault: fault)

        #expect(session.track("t1")?.clips.isEmpty == true)
        #expect(session.track("t2")?.clips.map(\.id) == ["take1-2-1"])
    }

    // MARK: The WAV guard (decision 0021)

    /// A pool file whose path is the WAV of a segment, or its temporary name, keeps its bytes:
    /// that segment stays unplaced, and the other segment is placed. Control (nil): with no such
    /// pool file, both segments are placed.
    @Test(arguments: [nil, "take1-1-1.wav", "./TAKE1-1-1.wav", ".take1-1-1.wav.tmp"])
    func aPoolFileWithAStemPathIsNotOverwritten(path: String?) throws {
        let userBytes = Data("the audio of the user".utf8)
        if let path {
            let clips = package.url.appending(path: "Clips")
            try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
            try userBytes.write(to: clips.appending(path: path))
            var session = try package.read()
            try session.addFile(AudioFile(id: "user", path: path, layout: .mono, length: 1_000))
            try session.write(to: package.url)
        }

        let session = try finalizeTake(of: package.read(), in: package.url)

        #expect(session.track("t2")?.clips.map(\.id) == ["take1-2-1"])
        guard let path else {
            #expect(session.track("t1")?.clips.map(\.id) == ["take1-1-1"])
            return
        }
        #expect(try Data(contentsOf: package.url.appending(path: "Clips/\(path)")) == userBytes)
        #expect(session.track("t1")?.clips.isEmpty == true)
        #expect(session.files["user"]?.path == path)
        #expect(unplacedSegments(segmentsWithAudio(in: package.url), session: session).map(\.stem) == ["take1-1-1"])
    }

    /// The WAV goes to `Clips/.<stem>.wav.tmp` and is renamed after its read-back, so a fault
    /// leaves no partial WAV under either name. A folder at the WAV path makes only the rename
    /// fail: a take-wide fault, so the take stays pending.
    @Test func aWAVRenameFaultKeepsTheTakePending() async throws {
        let clips = package.url.appending(path: "Clips")
        try FileManager.default.createDirectory(
            at: clips.appending(path: "take1-1-1.wav"), withIntermediateDirectories: true)

        let outcome = await completeTake(of: try package.read(), lock: try PackageLock(package.url))

        #expect(outcome.error == .finalize(.writeFailed(file: "Clips/take1-1-1.wav", status: EISDIR)))
        #expect(try package.read().recording?.take == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: clips.path) == ["take1-1-1.wav"])
    }

    // MARK: A moved package (decision 0014)

    /// The package moves during the read of the first segment. The WAV of that segment is gone
    /// from the old path, so the finalize throws, and no folder comes back at the old path. A
    /// second finalize on the new path places both segments.
    @Test func aRenameDuringTheFinalizeMakesNoGhostPackage() throws {
        let moved = package.folder.url.appending(path: "Moved.dirigible")
        let (old, new) = (package.url, moved)
        let fault = ReadFault(stem: "take1-1-1", block: 0) { _ = rename(old.path, new.path) }

        #expect(throws: FinalizeError.readFailed(file: "Clips/take1-1-1.wav", errno: ENOENT)) {
            try finalizeTake(of: package.read(), in: package.url, readFault: fault)
        }
        #expect(!FileManager.default.fileExists(atPath: package.url.path))
        let pending = try Session(contentsOf: moved)
        #expect(pending.recording?.take == 1)

        let session = try finalizeTake(of: pending, in: moved)
        #expect(session.track("t1")?.clips.map(\.id) == ["take1-1-1"])
        #expect(session.track("t2")?.clips.map(\.id) == ["take1-2-1"])
    }

    /// A listed CAF that goes away during the finalize is a take-wide fault, not an unplaced
    /// segment.
    @Test func aListedCAFThatGoesAwayThrows() throws {
        let second = file("take1-2-1.caf")
        let fault = ReadFault(stem: "take1-1-1", block: 0) { _ = unlink(second.path) }

        #expect(throws: FinalizeError.readFailed(file: "Capture/take1-2-1.caf", errno: ENOENT)) {
            try finalizeTake(of: package.read(), in: package.url, readFault: fault)
        }
    }

    /// The clips folder is made with `mkdir` of `Clips/` only, so a stale path gets no folder.
    /// Control: an existing package gets `Clips/`.
    @Test func createClipsFolderRefusesAMissingPackage() throws {
        let missing = package.folder.url.appending(path: "Missing.dirigible")

        #expect(throws: FinalizeError.writeFailed(file: "Clips", status: ENOENT)) {
            try createClipsFolder(in: missing)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        try createClipsFolder(in: package.url)
        #expect(FileManager.default.fileExists(atPath: package.url.appending(path: "Clips").path))
    }

    @Test func unplacedSegmentsSkipEmptyPlacedAndPendingCAFs() throws {
        let pending = try package.read()
        #expect(
            unplacedSegments(segmentsWithAudio(in: package.url), session: pending) == [],
            "the pending take is not listed")

        let session = try finalizeTake(of: pending, in: package.url)
        #expect(
            unplacedSegments(segmentsWithAudio(in: package.url), session: session) == [],
            "placed segments are not listed")

        try package.segment(take: 2, samples: [], checkpoints: [])
        try package.segment(take: 3, samples: sine(seconds: 0.1, rate: 48_000))
        #expect(unplacedSegments(segmentsWithAudio(in: package.url), session: session).map(\.stem) == ["take3-1-1"])
    }
}
