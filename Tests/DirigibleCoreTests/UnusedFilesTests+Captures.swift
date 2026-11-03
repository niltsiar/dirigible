import Foundation
import Testing

@testable import DirigibleCore

/// Decision 0047, amended for pre-roll (criterion P20 of run 2026-10-28-pre-roll): the prune of a
/// pool file of a segment also moves the CAF and the sidecar of that segment. `layout` stands in
/// for the `Capture/` paths that DirigibleAudio gives.
extension UnusedFilesTests {
    static let segment = CaptureID("take1-2-1")

    static func layout(_ capture: CaptureID) -> [String] {
        ["Capture/\(capture.rawValue).caf", "Capture/\(capture.rawValue).sidecar"]
    }

    /// `session` with the capture of each ID in `files`, and a pool file `<id>.wav` of that capture.
    static func withSegments(_ session: Session, _ files: [(FileID, CaptureID)]) throws -> Session {
        var session = session
        for (file, capture) in files {
            try session.addCapture(
                Capture(
                    id: capture, deviceUID: "mic", deviceName: "Mic", hostTimeNanos: 1, sampleTime: 0,
                    nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0))
            try session.addFile(
                AudioFile(id: file, path: "\(file.rawValue).wav", layout: .mono, length: 48_000, capture: capture))
        }
        return session
    }

    /// Writes the CAF (`cafBytes`) and the sidecar (3 bytes) of `capture` in `Capture/`.
    func plantCapture(_ capture: CaptureID, cafBytes: Int = 11) throws {
        let folder = package.appending(path: "Capture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: cafBytes).write(to: folder.appending(path: "\(capture.rawValue).caf"))
        try Data(count: 3).write(to: folder.appending(path: "\(capture.rawValue).sidecar"))
    }

    func captureExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: package.appending(path: "Capture/\(name)").path)
    }

    /// P20: a pool file with no clip whose capture is a segment is pruned, and the scan lists its
    /// capture, also when `session.xml` on the disk has the same pool entry with no clip.
    @Test func prunedCapturesAreListed() throws {
        let session = try Self.withSegments(Self.session([]), [("take1-2-1", Self.segment)])
        try session.write(to: package)
        try plant("take1-2-1.wav")

        let scan = try scan(session)

        #expect(scan.items.map(\.kind) == [.pool("take1-2-1")])
        #expect(scan.captures == [Self.segment])
    }

    /// P20 negative control: a capture that a used pool entry or a clip of a backup names stays.
    @Test func sharedCaptureIsNotListed() throws {
        var shared = try Self.withSegments(Self.session([]), [("take1-2-1", Self.segment)])
        try shared.addFile(
            AudioFile(id: "keep", path: "keep.wav", layout: .mono, length: 48_000, capture: Self.segment))
        try shared.place(Clip(id: "c", file: "keep", start: 0, offset: 0, length: 1), on: "a")
        try plant("take1-2-1.wav")
        try plant("keep.wav")
        #expect(try scan(shared).items.map(\.kind) == [.pool("take1-2-1")])
        #expect(try scan(shared).captures.isEmpty, "another pool entry names the capture")

        let alone = try Self.withSegments(Self.session([]), [("take1-2-1", Self.segment)])
        var backup = try Self.withSegments(Self.session([]), [("old", Self.segment)])
        try backup.place(Clip(id: "c", file: "old", start: 0, offset: 0, length: 1), on: "a")
        try self.backup(backup)
        #expect(try scan(alone).captures.isEmpty, "a clip of a backup names the capture")
    }

    /// P20: a pool file with no file on the disk frees no capture: its CAF is the last copy.
    @Test func aMissingWAVKeepsItsCapture() throws {
        let session = try Self.withSegments(Self.session([]), [("take1-2-1", Self.segment)])
        try plantCapture(Self.segment)

        let scan = try scan(session).listingCaptureFiles(Self.layout, in: package)

        #expect(scan.captures.isEmpty && scan.items.map(\.kind) == [.pool("take1-2-1")])
    }

    /// P20: the list has the CAF and the sidecar with their sizes, and the move order is the WAV,
    /// then the CAF, then the sidecar, after the save.
    @Test func captureFilesMoveAfterTheirWAV() throws {
        var session = try Self.withSegments(Self.session([]), [("take1-2-1", Self.segment)])
        try plant("take1-2-1.wav", bytes: 5)
        try plantCapture(Self.segment)
        let scan = try scan(session).listingCaptureFiles(Self.layout, in: package)
        #expect(scan.items.map(\.path) == ["Capture/take1-2-1.caf", "Capture/take1-2-1.sidecar", "take1-2-1.wav"])
        #expect(scan.items.map(\.bytes) == [11, 3, 5])
        var trashed: [String] = []

        let report = try scan.prune(&session, save: save) { url in
            trashed.append(url.lastPathComponent)
            return Self.fakeTrashURL(url)
        }

        #expect(trashed == ["take1-2-1.wav", "take1-2-1.caf", "take1-2-1.sidecar"])
        #expect(
            report.moved.map(\.item.path) == ["take1-2-1.wav", "Capture/take1-2-1.caf", "Capture/take1-2-1.sidecar"])
        #expect(report.failed.isEmpty && session.files["take1-2-1"] == nil)
    }

    /// P20: a WAV that does not move keeps its CAF and sidecar, so the segment is unplaced again
    /// and no audio is lost. The report names only the WAV.
    @Test func aWAVThatStaysKeepsItsCaptureFiles() throws {
        var session = try Self.withSegments(Self.session([]), [("take1-2-1", Self.segment)])
        try plant("take1-2-1.wav")
        try plantCapture(Self.segment)
        let scan = try scan(session).listingCaptureFiles(Self.layout, in: package)
        var trashed: [String] = []

        let report = try scan.prune(&session, save: save) { url in
            trashed.append(url.lastPathComponent)
            if url.pathExtension == "wav" { throw Self.refusal }
            return Self.fakeTrashURL(url)
        }

        #expect(trashed == ["take1-2-1.wav"])
        #expect(report.moved.isEmpty && report.failed.map(\.item.path) == ["take1-2-1.wav"])
        #expect(captureExists("take1-2-1.caf") && captureExists("take1-2-1.sidecar"))
    }

    /// P20: an edit after the scan that gives a clip to the pool file keeps its capture files.
    @Test func editAfterScanKeepsTheCaptureFiles() throws {
        var session = try Self.withSegments(Self.session([]), [("take1-2-1", Self.segment)])
        try plant("take1-2-1.wav")
        try plantCapture(Self.segment)
        let scan = try scan(session).listingCaptureFiles(Self.layout, in: package)
        try session.place(Clip(id: "c", file: "take1-2-1", start: 0, offset: 0, length: 1), on: "a")

        let report = try scan.prune(&session, save: save) { url in Self.fakeTrashURL(url) }

        #expect(report.moved.isEmpty && report.failed.isEmpty)
        #expect(captureExists("take1-2-1.caf") && captureExists("take1-2-1.sidecar"))
    }
}
