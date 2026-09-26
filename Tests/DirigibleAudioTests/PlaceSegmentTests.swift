import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// `Studio.place` of decision 0021 (criteria 5, 7, 8, 10 to 13, 24, 27 to 30): one unplaced
/// segment goes back on the timeline through the per-segment finalize, at its recorded track and
/// time from the take anchor, or at an explicit track and start.
///
/// Fixture, made off the main actor: a two-arm take 1 (playhead 96,000, first frame 10 ms after
/// the take start, latency 48) that the take finalize ended, then the clip and the pool file of
/// `take1-1-1` removed. The capture stays, and `Clips/take1-1-1.wav` stays as an orphan WAV.
struct PlaceSegmentTests {
    let package: TakePackage
    var clips: URL { package.url.appending(path: "Clips") }
    var anchor: URL { package.capture.appending(path: "take1.anchor") }

    static let segment = SegmentName(stem: "take1-1-1")!
    /// The clip of the take finalize: 96,000 + 480 (10 ms) - 48 (latency).
    static let recorded = Clip(id: "take1-1-1", file: "take1-1-1", start: 96_432, offset: 0, length: 96_000)

    init() throws {
        package = try TakePackage(tracks: [("t1", .mono), ("t2", .mono)])
        try package.segment(arm: 1, samples: sine(seconds: 2, rate: 48_000))
        try package.segment(arm: 2, samples: sine(seconds: 2, rate: 48_000, frequency: 500))
        var session = try finalizeTake(of: package.read(), in: package.url)
        try #require(session.track("t1")?.clips.map { $0 } == [Self.recorded])
        try session.clear(.zero..<Frames.limit, on: "t1")
        try session.removeFile("take1-1-1")
        try session.write(to: package.url)
    }

    /// Opens the fixture with the test environment and checks that `take1-1-1` is unplaced.
    @MainActor func studio(free: FreeBytes = FreeBytes()) async throws -> Studio {
        let studio = try await Studio.open(package.url)
        studio.environment = .test(TestHAL([]), free: free)
        return studio
    }

    /// The names and sizes of the files in `folder`.
    func listing(_ folder: URL) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: folder.appending(path: name).path)
            result[name] = (attributes[.size] as? NSNumber)?.intValue ?? -1
        }
        return result
    }

    /// The bytes of each regular file in `Clips/`.
    func clipBytes() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: clips.path) {
            var folder: ObjCBool = false
            FileManager.default.fileExists(atPath: clips.appending(path: name).path, isDirectory: &folder)
            result[name] = folder.boolValue ? Data() : try Data(contentsOf: clips.appending(path: name))
        }
        return result
    }

    func temporaryFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: clips.path).filter { $0.hasSuffix(".tmp") }
    }

    // MARK: Criteria 5 and 7

    @Test @MainActor func aPlacementWithTheAnchorRestoresTheRecordedClip() async throws {
        let studio = try await studio()
        #expect(studio.unplacedSegments == [Self.segment])
        let capture = try listing(package.capture)

        let id = try await studio.place(Self.segment)

        #expect(id == "take1-1-1")
        #expect(studio.session.track("t1")?.clips.map { $0 } == [Self.recorded])
        #expect(studio.unplacedSegments == [])
        #expect(studio.transport == .idle)
        #expect(studio.takeError == nil)
        #expect(try package.read() == studio.session, "the placement is saved")
        #expect(try listing(package.capture) == capture, "Capture/ does not change (criterion 24)")
    }

    enum Explicit: String, CaseIterable, CustomTestStringConvertible {
        case trackAndStart, startOnly, trackOnly
        var testDescription: String { rawValue }
    }

    @Test(arguments: Explicit.allCases)
    @MainActor func anExplicitTrackOrStartReplacesTheAnchor(explicit: Explicit) async throws {
        let studio = try await studio()
        let expected: (track: TrackID, start: Frames)
        switch explicit {
        case .trackAndStart:
            _ = try await studio.place(Self.segment, on: "t2", at: 1_000)
            expected = ("t2", 1_000)
        case .startOnly:
            _ = try await studio.place(Self.segment, at: 1_000)
            expected = ("t1", 1_000)
        case .trackOnly:
            _ = try await studio.place(Self.segment, on: "t2")
            expected = ("t2", 96_432)
        }

        let clip = studio.session.track(expected.track)?.clips.first { $0.id == "take1-1-1" }
        #expect(clip == Clip(id: "take1-1-1", file: "take1-1-1", start: expected.start, offset: 0, length: 96_000))
        #expect(studio.unplacedSegments == [])
    }

    // MARK: Criteria 8, 29, 30

    enum Refusal: String, CaseIterable, CustomTestStringConvertible {
        case placed, pendingTake, noCAF, missingSidecar, badMagicSidecar, noAnchor, noAnchorNoTrack, noAnchorNoStart
        case wavInUse, wavInUseOtherCase, layoutMismatch, beforeTimeline, unreadableAnchor, armOutsideTheAnchor
        case negativeStart
        var testDescription: String { rawValue }
    }

    /// Changes the fixture for `refusal` and returns the call and its error.
    func prepare(_ refusal: Refusal) throws -> (
        segment: SegmentName, track: TrackID?, start: Frames?, error: StudioError
    ) {
        let s = Self.segment
        func refused(_ fault: SegmentFault, _ segment: SegmentName = s, track: TrackID? = nil, start: Frames? = nil)
            -> (SegmentName, TrackID?, Frames?, StudioError)
        { (segment, track, start, .segment(segment, fault)) }
        switch refusal {
        case .placed:
            return refused(.notUnplaced, SegmentName(stem: "take1-2-1")!)
        case .pendingTake:
            // Take 2 is pending, and a marker makes the open skip its finalize (decision 0004).
            try package.segment(take: 2, samples: sine(seconds: 1, rate: 48_000))
            var session = try package.read()
            try session.setRecording(
                Recording(take: 2, playheadFrame: 0, takeStartHostTimeNanos: takeStart, armedTracks: ["t1"]))
            try session.write(to: package.url)
            FileManager.default.createFile(atPath: package.url.appending(path: "recovery-attempt").path, contents: nil)
            return refused(.notUnplaced, SegmentName(stem: "take2-1-1")!)
        case .noCAF:
            return refused(.notUnplaced, SegmentName(stem: "take1-1-9")!)
        case .missingSidecar:
            try FileManager.default.removeItem(at: package.capture.appending(path: "take1-1-1.sidecar"))
            return refused(.noSidecar)
        case .badMagicSidecar:
            let handle = try FileHandle(forWritingTo: package.capture.appending(path: "take1-1-1.sidecar"))
            try handle.write(contentsOf: Data("XXXXXXXX".utf8))
            try handle.close()
            return refused(.noSidecar)
        case .noAnchor:
            try FileManager.default.removeItem(at: anchor)
            return refused(.noAlignment)
        case .noAnchorNoTrack:
            try FileManager.default.removeItem(at: anchor)
            return refused(.noAlignment, start: 1_000)
        case .noAnchorNoStart:
            try FileManager.default.removeItem(at: anchor)
            return refused(.noAlignment, track: "t1")
        case .wavInUse, .wavInUseOtherCase:
            let path = refusal == .wavInUse ? "take1-1-1.wav" : "./TAKE1-1-1.wav"
            var session = try package.read()
            try session.addFile(AudioFile(id: "user", path: path, layout: .mono, length: 1_000))
            try session.write(to: package.url)
            return refused(.wavInUse("user"))
        case .layoutMismatch:
            try package.segment(
                arm: 1, header: TakePackage.header(channels: 2), samples: sine(seconds: 2, rate: 48_000, channels: 2))
            return refused(.session(.layoutMismatch("t1", .file("take1-1-1"))))
        case .beforeTimeline:
            try package.segment(
                arm: 1, header: TakePackage.header(firstHost: takeStart - 5_000_000_000),
                samples: sine(seconds: 2, rate: 48_000))
            return refused(.beforeTimeline)
        case .unreadableAnchor:
            chmod(anchor.path, 0o000)
            return (s, nil, nil, .finalize(.readFailed(file: "Capture/take1.anchor", errno: EACCES)))
        case .armOutsideTheAnchor:
            try package.segment(arm: 3, samples: sine(seconds: 1, rate: 48_000))
            return refused(.noAlignment, SegmentName(stem: "take1-3-1")!)
        case .negativeStart:
            // The library refuses it at its boundary, as the CLI does (exit 64).
            return refused(.session(.frameOutOfRange), start: -1)
        }
    }

    /// A refusal throws its error and changes nothing: the session, `session.xml`, the undo stack,
    /// `Capture/` (names and sizes), and the bytes of each file in `Clips/`. No temporary WAV stays.
    @Test(arguments: Refusal.allCases)
    @MainActor func aRefusedPlacementChangesNothing(refusal: Refusal) async throws {
        let call = try prepare(refusal)
        defer { chmod(anchor.path, 0o644) }
        let studio = try await studio()
        let (session, xml) = (studio.session, try Data(contentsOf: package.url.appending(path: "session.xml")))
        let (capture, clipFiles, canUndo) = (try listing(package.capture), try clipBytes(), studio.canUndo)

        await #expect(throws: call.error) { try await studio.place(call.segment, on: call.track, at: call.start) }

        #expect(studio.session == session)
        #expect(try Data(contentsOf: package.url.appending(path: "session.xml")) == xml)
        #expect(studio.canUndo == canUndo)
        #expect(studio.transport == .idle)
        #expect(studio.takeError == nil)
        #expect(try listing(package.capture) == capture)
        #expect(try clipBytes() == clipFiles)
    }

    // MARK: Criteria 10 to 13

    /// Control of the entry: undo makes the segment unplaced again, and a redo places it again.
    @Test @MainActor func aPlacementIsOneUndoEntry() async throws {
        let studio = try await studio()
        #expect(!studio.canUndo)
        _ = try await studio.place(Self.segment)

        try studio.undo()

        #expect(!studio.canUndo, "one entry")
        #expect(studio.unplacedSegments == [Self.segment])
        #expect(studio.session.track("t1")?.clips.map { $0 } == [])
        #expect(FileManager.default.fileExists(atPath: clips.appending(path: "take1-1-1.wav").path))

        try studio.redo()

        #expect(studio.session.track("t1")?.clips.map { $0 } == [Self.recorded])
        #expect(studio.unplacedSegments == [])
    }

    /// A gate in the block read holds the conversion. Every entry point that changes the session
    /// or the package is busy; the placement goes on and ends with the clip when the gate opens.
    @Test @MainActor func aPlacementIsBusyUntilItEnds() async throws {
        let studio = try await studio()
        let gate = Gate()
        studio.environment.placeRead = ReadFault(stem: "take1-1-1", block: 0) { gate.waitOnce() }
        let out = package.folder.url.appending(path: "mix.caf")
        let source = try #require(ExportSource(range: 0..<4_800))

        let placing = Task { try await studio.place(Self.segment) }
        await gate.entered()

        #expect(studio.transport == .placing(Self.segment))
        #expect(throws: StudioError.busy) { try studio.edit { _ throws(SessionError) in } }
        #expect(throws: StudioError.busy) { try studio.undo() }
        await #expect(throws: StudioError.busy) { try await studio.retryFinalize() }
        await #expect(throws: StudioError.busy) { try await studio.startRecording(armed: ["t1"]) }
        await #expect(throws: StudioError.busy) { try await studio.export(source, .render, to: out, replacing: nil) }
        await #expect(throws: StudioError.busy) { try await studio.place(Self.segment) }
        gate.open()

        #expect(try await placing.value == "take1-1-1")
        #expect(studio.session.track("t1")?.clips.map { $0 } == [Self.recorded])
        #expect(studio.transport == .idle)
    }

    /// The hook runs at the block read itself, so it reports the thread of the conversion.
    @Test @MainActor func theConversionRunsOffTheMainThread() async throws {
        let studio = try await studio()
        let onMain = LockedBox<Bool>()
        studio.environment.placeRead = ReadFault(stem: "take1-1-1", block: 0) { onMain.value = Thread.isMainThread }

        _ = try await studio.place(Self.segment)

        #expect(onMain.value == false)
    }

    /// An orphan WAV and an orphan temporary WAV from a crash in a placement do not block: the
    /// placement replaces the WAV with the frames of the segment and leaves no temporary file.
    @Test @MainActor func anOrphanWAVIsReplaced() async throws {
        var random = SeededGenerator(seed: 13)
        let noise = Data((0..<50_000).map { _ in UInt8.random(in: 0...255, using: &random) })
        try noise.write(to: clips.appending(path: "take1-1-1.wav"))
        try noise.write(to: clips.appending(path: ".take1-1-1.wav.tmp"))
        let studio = try await studio()
        #expect(studio.unplacedSegments == [Self.segment])

        _ = try await studio.place(Self.segment)

        let placed = try readAudio(clips.appending(path: "take1-1-1.wav")).samples
        let segment = try readAudio(package.capture.appending(path: "take1-1-1.caf")).samples
        #expect(placed.count == 96_000 && segment.count == 96_000)
        // Tolerance: 24-bit quantization of the WAV, ± 1e-6 of full scale.
        #expect(zip(placed, segment).allSatisfy { abs($0 - $1) <= 1e-6 })
        #expect(try temporaryFiles() == [])
    }

    // MARK: Criteria 27 and 28

    /// The rule of a finalize for one segment: 3 WAV bytes for each 4 CAF bytes, plus 1 GB. Both
    /// sides of the boundary.
    @Test @MainActor func aPlacementOnALowDiskIsRefused() async throws {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: package.capture.appending(path: "take1-1-1.caf").path)
        let caf = try #require((attributes[.size] as? NSNumber)?.int64Value)
        let free = FreeBytes(caf * 3 / 4 + diskMargin - 1)
        let studio = try await studio(free: free)
        let (session, clipFiles) = (studio.session, try clipBytes())

        await #expect(throws: StudioError.diskLow) { try await studio.place(Self.segment) }

        #expect(studio.session == session)
        #expect(try clipBytes() == clipFiles)
        #expect(studio.transport == .idle)

        free.value += 1
        _ = try await studio.place(Self.segment)
        #expect(studio.session.track("t1")?.clips.map { $0 } == [Self.recorded])
    }

    /// A folder at the WAV path makes the rename fail: the error is thrown, the session does not
    /// change, and no temporary WAV stays.
    @Test @MainActor func aWriteFaultLeavesNoPartialWAV() async throws {
        try FileManager.default.removeItem(at: clips.appending(path: "take1-1-1.wav"))
        try FileManager.default.createDirectory(
            at: clips.appending(path: "take1-1-1.wav"), withIntermediateDirectories: false)
        let studio = try await studio()
        let session = studio.session

        await #expect(throws: StudioError.finalize(.writeFailed(file: "Clips/take1-1-1.wav", status: EISDIR))) {
            try await studio.place(Self.segment)
        }

        #expect(studio.session == session)
        #expect(try temporaryFiles() == [])
        #expect(studio.unplacedSegments == [Self.segment])
    }

    /// A placement stops a play before its conversion, as a take start does, and a play after it
    /// hears the placed clip. The clip of `t2` moves after the placed clip, so only the placed
    /// clip can sound at its start.
    @Test @MainActor func aPlacementStopsThePlay() async throws {
        let studio = try await studio()
        try studio.edit { session throws(SessionError) in try session.move("take1-2-1", to: "t2", start: 300_000) }
        await studio.perform(.seek(.frame(96_432)))
        await studio.perform(.playStop)
        let silence = await studio.renderOffline(frames: 4_800)
        #expect(silence.joined().allSatisfy { $0 == 0 }, "control: no clip sounds before the placement")
        #expect(studio.playback != .stopped)
        let gate = Gate()
        studio.environment.placeRead = ReadFault(stem: "take1-1-1", block: 0) { gate.waitOnce() }

        let placing = Task { try await studio.place(Self.segment) }
        await gate.entered()

        #expect(studio.playback == .stopped)
        gate.open()
        _ = try await placing.value

        await studio.perform(.seek(.frame(96_432)))
        await studio.perform(.playStop)
        let sound = await studio.renderOffline(frames: 4_800)
        #expect(sound.joined().contains { abs($0) > 0.1 }, "the placed clip sounds")
        await studio.perform(.playStop)
    }
}
