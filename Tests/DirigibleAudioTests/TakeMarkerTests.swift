import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// F107 criteria C1 to C7 and C16: a marker at the record head while a take records. Track t1
/// (mono, `mic`) has c1, and track t2 (mono, `box`) has c2: 3 s of a sine each. Each take starts
/// at frame 96 000 of 48 000 Hz, so a host time 1.5 s after the take start is frame 168 000.
@MainActor
struct TakeMarkerTests {
    let package: MixPackage
    var url: URL { package.url }
    static let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!
    static let box = InputDevice(
        uid: "box", name: "Box", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!
    /// 0.5 s after the take start: frame 120 000, inside the clip of a take of 1 s or more.
    static let inTake = takeStart + 500_000_000

    init() throws {
        package = try MixPackage()
        try package.addFile("f1", channels: tone([(3, -24)], layout: .mono))
        try package.addFile("f2", channels: tone([(3, -30)], layout: .mono))
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 144_000)
        try package.addTrack("t2", clip: "c2", file: "f2", start: 0, offset: 0, length: 144_000)
        try package.session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        try package.session.setRoute(Route.device(uid: "box", channels: .mono(1)), track: "t2")
        try package.session.write(to: package.url)
    }

    func studio() async throws -> Studio {
        let studio = try await Studio.open(url)
        studio.environment = .test(TestHAL([Self.mic, Self.box]))
        return studio
    }

    /// Starts a take at frame 96 000 on `armed` with a new test HAL, and returns the HAL.
    func start(_ studio: Studio, armed: [TrackID] = ["t1"]) async throws -> TestHAL {
        let hal = TestHAL([Self.mic, Self.box])
        studio.environment = .test(hal)
        _ = try await studio.startTake(
            armed: armed, devices: [Self.mic, Self.box], playhead: 96_000, hostTimeNanos: takeStart)
        return hal
    }

    /// Plays `seconds` of a sine at `dBFS` from the take start on each device of `uids`, and
    /// waits until the writer drained each ring to disk.
    func play(_ hal: TestHAL, _ uids: [String], seconds: Double, dBFS: Double = -30) async {
        for uid in uids {
            let input = SyntheticInput(hal, uid)
            input.play(records(tone([(seconds, dBFS)], layout: .mono), layout: [1], rate: 48_000, hostStart: takeStart))
            await input.wait()
            await drained(hal, uid, limit: .seconds(20))
        }
    }

    /// A take of 1 s at `dBFS` on t1 with a marker at frame 120 000, then the stop.
    func takeWithMarker(_ studio: Studio, dBFS: Double) async throws -> Marker {
        let hal = try await start(studio)
        await play(hal, ["mic"], seconds: 1, dBFS: dBFS)
        let marker = try studio.addMarkerAtRecordHead(.marker, name: "Marker 1", atHostNanos: Self.inTake)
        try await studio.stopRecording()
        return marker
    }

    // MARK: C1 and C2

    @Test func aTakeMarkerIsAtTheRecordHeadOfItsHostTime() async throws {
        let studio = try await studio()
        _ = try await start(studio)
        let time = takeStart + 1_500_000_000

        let marker = try studio.addMarkerAtRecordHead(.marker, name: "Marker 1", atHostNanos: time)
        let later = try studio.addMarkerAtRecordHead(.marker, name: "Marker 2", atHostNanos: time + 1_000_000)

        #expect(marker.position == 168_000, "the marker 1.5 s after the take start: \(marker.position)")
        #expect(later.position == 168_048, "the marker 1 ms later: \(later.position)")
        #expect(
            studio.session.markers[marker.id]
                == Marker(id: marker.id, name: "Marker 1", position: 168_000, kind: .marker))
        #expect(studio.session.markers.count == 2, "markers: \(studio.session.sortedMarkers)")
        try await studio.stopRecording()
    }

    @Test func aTakeChapterIsAChapter() async throws {
        let studio = try await studio()
        _ = try await start(studio)

        let chapter = try studio.addMarkerAtRecordHead(.chapter, name: "Intro", atHostNanos: takeStart + 1_500_000_000)

        #expect(
            studio.session.markers[chapter.id]
                == Marker(id: chapter.id, name: "Intro", position: 168_000, kind: .chapter))
        try await studio.stopRecording()
    }

    // MARK: C3

    @Test func aTakeMarkerIsOnDiskWhileTheTakeRecords() async throws {
        let studio = try await studio()
        _ = try await start(studio)
        let started = try Session(contentsOf: url)
        #expect(started.markers.isEmpty && started.recording != nil, "control: the take start save")

        let marker = try studio.addMarkerAtRecordHead(.marker, name: "Marker 1", atHostNanos: Self.inTake)
        await studio.serialized {}

        #expect(studio.transport == .recording(take: 1), "after the save turn: \(studio.transport)")
        let saved = try Session(contentsOf: url)
        #expect(saved.markers[marker.id] == marker, "session.xml has no take marker")
        #expect(saved.recording != nil && saved.recording == studio.session.recording, "session.xml lost the take")
        try await studio.stopRecording()
    }

    // MARK: C4

    enum UndoCase: CaseIterable { case silentTake, toneTake, retake }

    /// C4a and C4c: a silent take adds no level entry. C4b: the level of a -30 dBFS take adds one.
    @Test(arguments: UndoCase.allCases)
    func theFinalizeKeepsTakeMarkersAndUndoRemovesTheTakeFirst(_ fixture: UndoCase) async throws {
        let studio = try await studio()
        let marker = try await takeWithMarker(studio, dBFS: fixture == .toneTake ? -30 : -.infinity)
        #expect(studio.session.markers[marker.id] == marker, "\(fixture): the finalize lost the marker")
        #expect(studio.session.clip("take1-1-1") != nil, "\(fixture): no take clip")

        if fixture == .toneTake {
            try studio.undo()
            StopLevelTests.expectGain(studio.session, "take1-1-1", 0, tolerance: 0, "C4b undo of the level")
            #expect(studio.session.markers[marker.id] == marker, "C4b: the undo of the level removed the marker")
        }
        try studio.undo()
        #expect(studio.session.markers[marker.id] == marker, "\(fixture): the undo of the take removed the marker")
        #expect(studio.clipIDs(ofTake: 1).isEmpty, "\(fixture): the undo of the take kept a take clip")

        if fixture == .retake {
            let hal = try await start(studio)
            let second = try #require(studio.session.recording?.take)
            await play(hal, ["mic"], seconds: 1, dBFS: -.infinity)
            try await studio.stopRecording()
            #expect(studio.session.markers[marker.id] == marker, "C4c: the retake lost the marker")
            #expect(!studio.clipIDs(ofTake: second).isEmpty, "C4c: the retake has no take clip")
            try studio.undo()
            #expect(studio.session.markers[marker.id] == marker, "C4c: the undo of the retake removed the marker")
            #expect(studio.clipIDs(ofTake: second).isEmpty, "C4c: the undo of the retake kept a take clip")
        } else {
            try studio.undo()
            #expect(studio.session.markers.isEmpty, "\(fixture): the last undo kept the marker")
            #expect(!studio.canUndo, "\(fixture): more entries than the take, its level, and the marker")
        }
    }

    // MARK: C5

    @Test func aRecoveredTakeKeepsItsMarkers() async throws {
        let studio = try await studio()
        let hal = try await start(studio)
        await play(hal, ["mic"], seconds: 2)
        let marker = try studio.addMarkerAtRecordHead(.marker, name: "Marker 1", atHostNanos: Self.inTake)
        await studio.serialized {}
        // The copy holds the files of a crash now: the take records, and its writer is open.
        let copy = package.folder.url.appending(path: "Crash.dirigible")
        try FileManager.default.copyItem(at: url, to: copy)
        try await studio.stopRecording()

        let recovered = try await Studio.open(copy)

        #expect(recovered.session.recording == nil && recovered.takeError == nil, "the recovery left the take pending")
        #expect(recovered.session.markers[marker.id] == marker, "the recovery lost the marker")
        let clip = try #require(recovered.session.clip("take1-1-1")?.clip, "the recovery placed no take clip")
        #expect(clip.range.contains(marker.position), "the take clip \(clip.range) does not hold the marker")
    }

    // MARK: C6

    /// One refused call in state `label`: `.busy` and no change of the session or of the undo stack.
    func expectBusy(_ studio: Studio, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let (session, revision, canUndo) = (studio.session, studio.sessionRevision, studio.canUndo)
        #expect(!studio.canAddTakeMarker, "\(label): canAddTakeMarker is true", sourceLocation: sourceLocation)
        #expect(throws: StudioError.busy, "\(label)", sourceLocation: sourceLocation) {
            try studio.addMarkerAtRecordHead(.marker, name: "Marker 1", atHostNanos: Self.inTake)
        }
        let same = studio.session == session && studio.sessionRevision == revision && studio.canUndo == canUndo
        #expect(same, "\(label): the refused call changed the session", sourceLocation: sourceLocation)
    }

    @Test func aTakeMarkerOutsideARecordingIsBusy() async throws {
        let studio = try await studio()
        #expect(studio.transport == .idle && !studio.isStarting)
        expectBusy(studio, "idle")
        let segment = try #require(SegmentName(stem: "take1-1-1"))
        for state in [
            Studio.Transport.placing(segment), .importing(ImportRun(name: "x", kind: .file, flags: ImportFlags())),
        ] {
            studio.transport = state
            expectBusy(studio, "\(state)")
        }
        studio.transport = .idle

        // A held write keeps the take start waiting for its turn.
        let startHold = AsyncGate()
        let hold = Task { await studio.serialized { await startHold.wait() } }
        await startHold.entered()
        studio.environment = .test(TestHAL([Self.mic, Self.box]))
        let starting = Task {
            try await studio.startTake(
                armed: ["t1"], devices: [Self.mic, Self.box], playhead: 96_000, hostTimeNanos: takeStart)
        }
        await until("the take start did not begin") { studio.isStarting }
        expectBusy(studio, "isStarting")
        startHold.open()
        await hold.value
        _ = try await starting.value

        #expect(studio.transport == .recording(take: 1) && studio.canAddTakeMarker, "recording: \(studio.transport)")
        let marker = try studio.addMarkerAtRecordHead(.marker, name: "Marker 1", atHostNanos: Self.inTake)
        #expect(studio.session.markers.values.map(\.id) == [marker.id], "recording: \(studio.session.sortedMarkers)")
        await studio.serialized {}

        let finalizeHold = AsyncGate()
        studio.environment.beforeFinalize = { await finalizeHold.wait() }
        let stopping = Task { try await studio.stopRecording() }
        await finalizeHold.entered()
        #expect(studio.transport == .finalizing(take: 1), "finalize hold: \(studio.transport)")
        expectBusy(studio, "finalizing")
        finalizeHold.open()
        try await stopping.value

        // The settle waits for a held write before it stops the second take.
        _ = try await start(studio)
        let take = try #require(studio.session.recording?.take)
        let settleHold = AsyncGate()
        let held = Task { await studio.serialized { await settleHold.wait() } }
        await settleHold.entered()
        let settle = Task { await studio.settle() }
        await until("the settle did not begin") { studio.settling }
        #expect(studio.transport == .recording(take: take), "settle hold: \(studio.transport)")
        expectBusy(studio, "settling")
        settleHold.open()
        await held.value
        await settle.value
    }

    // MARK: C7

    @Test func aTakeOnTwoDevicesGetsOneMarker() async throws {
        let studio = try await studio()
        let hal = try await start(studio, armed: ["t1", "t2"])
        await play(hal, ["mic", "box"], seconds: 1)

        let marker = try studio.addMarkerAtRecordHead(.marker, name: "Marker 1", atHostNanos: Self.inTake)
        try await studio.stopRecording()

        #expect(studio.session.markers.values.map(\.id) == [marker.id], "markers: \(studio.session.sortedMarkers)")
        let clips = studio.clipIDs(ofTake: 1).compactMap { studio.session.clip($0) }
        #expect(Set(clips.map(\.track)) == ["t1", "t2"], "take clips: \(clips.map(\.clip.id))")
        for (clip, track) in clips {
            #expect(clip.range.contains(marker.position), "\(track): the take clip \(clip.range) misses the marker")
        }
    }

    // MARK: C16

    @Test func aGoodFinalizeClearsATakeMarkerSaveError() async throws {
        let studio = try await studio()
        let hal = try await start(studio)
        studio.environment.saveSession = { _, _ throws(SessionFileError) in throw .writeFailed(step: "test", errno: EIO)
        }
        await play(hal, ["mic"], seconds: 1, dBFS: -.infinity)
        let marker = try studio.addMarkerAtRecordHead(.marker, name: "Marker 1", atHostNanos: Self.inTake)
        await studio.serialized {}
        #expect(studio.saveError != nil, "control: the save of the take marker did not fail")

        try await studio.stopRecording()

        #expect(studio.saveError == nil, "the finalize kept the save error \(String(describing: studio.saveError))")
        #expect(try Session(contentsOf: url).markers[marker.id] == marker, "session.xml has no take marker")
    }
}
