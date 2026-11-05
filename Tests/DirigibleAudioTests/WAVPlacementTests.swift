import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A placement from the WAV of a segment whose CAF is gone (decision 0071, C7): the finalize
/// record in the sidecar gives the capture and the clip gain, and the WAV stays as it is.
@MainActor
struct WAVPlacementTests {
    let folder: TemporaryFolder
    let url: URL
    var capture: URL { url.appending(path: "Capture") }
    var clips: URL { url.appending(path: "Clips") }
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 48)!
    let box = InputDevice(
        uid: "box", name: "Box", nominalRate: 44_100, availableRates: [44_100...44_100], channelsPerBuffer: [2],
        latency: 0)!
    static let segments = [SegmentName(stem: "take1-1-1")!, SegmentName(stem: "take1-2-1")!]

    /// Track `t1` (mono, `mic`) and track `t2` (stereo, `box`).
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .stereo)
        try session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        try session.setRoute(Route.device(uid: "box", channels: .stereo(1, 2)), track: "t2")
        try session.write(to: url)
    }

    /// Records take 1 for 2 s and stops it. The mic sine has a float peak of 2.0, so its clip
    /// gain is not 0 dB.
    func recordAndStop(_ studio: Studio) async throws {
        let hal = TestHAL([mic, box])
        studio.environment = .test(hal)
        _ = try await studio.startTake(
            armed: ["t1", "t2"], devices: [mic, box], playhead: 0, hostTimeNanos: takeStart)
        let micInput = SyntheticInput(hal, "mic")
        let boxInput = SyntheticInput(hal, "box")
        micInput.play(
            records(
                [sine(seconds: 2, rate: 48_000).map { $0 * 4 }], layout: [1], rate: 48_000,
                hostStart: takeStart + 1_000_000))
        boxInput.play(records([sine(seconds: 2, rate: 44_100, channels: 2)], layout: [2], rate: 44_100))
        await micInput.wait()
        await boxInput.wait()
        try await studio.stopRecording()
    }

    func sidecar(_ name: SegmentName) throws -> Sidecar? {
        try Sidecar.decode(Data(contentsOf: capture.appending(path: "\(name.stem).sidecar")))
    }

    func wavFacts(_ name: SegmentName) throws -> (inode: Int, bytes: Data) {
        let path = clips.appending(path: "\(name.stem).wav").path
        let inode = try #require(FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int)
        return (inode, try Data(contentsOf: URL(filePath: path)))
    }

    @Test func anUndoneTakePlacesFromItsWAV() async throws {
        let studio = try await Studio.open(url)
        try await recordAndStop(studio)
        for name in Self.segments {
            #expect(try sidecar(name)?.finalized != nil, "\(name) has a finalize record")
            // The CAF removal of decision 0071, by hand.
            try FileManager.default.removeItem(at: capture.appending(path: "\(name.stem).caf"))
        }
        let wavs = try Self.segments.map(wavFacts)
        // The undo entry of the level of the take (decision 0031) comes first, then the take. A
        // placement gives the clips of the take before the level.
        let stopped = studio.session
        try studio.undo()
        let first = studio.session.files.isEmpty ? stopped : studio.session
        if !studio.session.files.isEmpty { try studio.undo() }
        #expect(studio.session.files.isEmpty, "the undo removed the take")
        let firstClips = Dictionary(uniqueKeysWithValues: first.tracks.flatMap(\.clips).map { ($0.id, $0) })
        #expect(firstClips["take1-1-1"].map { $0.gain != .zero } == true, "the 2.0 peak gives a clip gain")
        #expect(studio.unplacedSegments == Self.segments)
        for name in Self.segments { _ = try await studio.place(name) }

        for name in Self.segments {
            let id = CaptureID(name.stem)
            #expect(studio.session.captures[id] == first.captures[id], "\(name) capture")
            #expect(studio.session.files[FileID(name.stem)] == first.files[FileID(name.stem)], "\(name) file")
            let clip = studio.session.tracks.flatMap(\.clips).first { $0.id == ClipID(name.stem) }
            #expect(clip == firstClips[ClipID(name.stem)], "\(name) clip: start, length, and gain")
        }
        #expect(studio.unplacedSegments == [])
        let after = try Self.segments.map(wavFacts)
        #expect(after.map(\.inode) == wavs.map(\.inode))
        let same = after.map(\.bytes) == wavs.map(\.bytes)
        #expect(same, "the WAV bytes do not change")
        #expect(try Session(contentsOf: url) == studio.session, "the placement is saved")
    }

    /// Records take 1, removes both CAFs, and undoes the take: both segments are WAV-backed and
    /// unplaced. Returns the session of the take before the level of decision 0031.
    func undoneTakeWithNoCAF(_ studio: Studio) async throws -> Session {
        try await recordAndStop(studio)
        for name in Self.segments {
            try FileManager.default.removeItem(at: capture.appending(path: "\(name.stem).caf"))
        }
        let stopped = studio.session
        try studio.undo()
        let first = studio.session.files.isEmpty ? stopped : studio.session
        if !studio.session.files.isEmpty { try studio.undo() }
        try #require(studio.unplacedSegments == Self.segments)
        return first
    }

    @Test func aRedoAfterTheUndoRestoresTheClips() async throws {
        let studio = try await Studio.open(url)
        let first = try await undoneTakeWithNoCAF(studio)

        try studio.redo()

        #expect(studio.session.tracks.map(\.clips) == first.tracks.map(\.clips))
        #expect(studio.unplacedSegments == [])
    }

    /// A WAV that goes after the scan of the studio (the unplaced list is the last scan): the
    /// placement error names the WAV, not the CAF that is gone, and the session does not change.
    @Test func aPlacementWithAMissingWAVNamesTheWAV() async throws {
        let studio = try await Studio.open(url)
        _ = try await undoneTakeWithNoCAF(studio)
        let name = Self.segments[0]
        try FileManager.default.removeItem(at: clips.appending(path: "\(name.stem).wav"))
        let before = studio.session

        await #expect(throws: StudioError.finalize(.readFailed(file: "Clips/\(name.stem).wav", errno: ENOENT))) {
            try await studio.place(name)
        }

        #expect(studio.session == before)
        #expect(try Session(contentsOf: url) == before)
    }

    /// A placement from the WAV converts nothing, so it needs only the disk margin.
    @Test func aWAVPlacementNeedsNoSpaceForAConversion() async throws {
        let studio = try await Studio.open(url)
        _ = try await undoneTakeWithNoCAF(studio)
        let free = FreeBytes(diskMargin)
        studio.environment = .test(TestHAL([]), free: free)

        _ = try await studio.place(Self.segments[0])

        #expect(studio.unplacedSegments == [Self.segments[1]])
        free.value = diskMargin - 1
        await #expect(throws: StudioError.placementSpace(needed: diskMargin, free: diskMargin - 1)) {
            try await studio.place(Self.segments[1])
        }
    }

    /// A stem WAV whose CAF is gone with no finalize record (a CAF that a user deleted) is not a
    /// segment: its timing and gain are not known. Control: the same files with the record.
    @Test func aStemWAVWithNoCAFAndNoRecordIsNotASegment() async throws {
        let studio = try await Studio.open(url)
        try await recordAndStop(studio)
        let name = Self.segments[0]
        let sidecarURL = capture.appending(path: "\(name.stem).sidecar")
        try FileManager.default.removeItem(at: capture.appending(path: "\(name.stem).caf"))
        #expect(segmentsWithAudio(in: url).contains(name))
        let data = try Data(contentsOf: sidecarURL)
        let stripped = try #require(try Sidecar.decode(data))
        let bytes = stripped.checkpoints.reduce(Sidecar.encode(stripped.header)) { $0 + Sidecar.encode($1) }
        try bytes.write(to: sidecarURL)

        #expect(!segmentsWithAudio(in: url).contains(name))
        #expect(segmentsWithAudio(in: url).contains(Self.segments[1]))
    }
}
