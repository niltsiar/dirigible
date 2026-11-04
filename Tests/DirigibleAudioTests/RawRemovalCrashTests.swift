import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A stop save that fails and a crash at each removal step (decision 0071, C4 and C5): each
/// segment keeps its WAV in the session or its CAF with frames, at the instant of the fault and
/// after an open of the package and of a copy made at that instant.
@MainActor
struct RawRemovalCrashTests {
    static let segments = [SegmentName(stem: "take1-1-1")!, SegmentName(stem: "take1-2-1")!]

    /// A pending take 1 with a 2 s segment on each of `t1` and `t2`, on a clock that passes the gate.
    static func take() throws -> TakePackage {
        let package = try TakePackage(tracks: [("t1", .mono), ("t2", .mono)])
        try package.segment(arm: 1, samples: sine(seconds: 2, rate: 48_000))
        try package.segment(arm: 2, samples: sine(seconds: 2, rate: 48_000, frequency: 500))
        return package
    }

    /// True when a clip of `session` uses the WAV of `name` and the WAV is in `Clips/`, or when
    /// the CAF of `name` has frames.
    static func hasAudio(_ name: SegmentName, session: Session, in package: URL) -> Bool {
        let wav = "\(name.stem).wav"
        let placed =
            session.tracks.contains { $0.clips.contains { session.files[$0.file]?.path == wav } }
            && FileManager.default.fileExists(atPath: package.appending(path: "Clips/\(wav)").path)
        let caf = try? AVAudioFile(forReading: package.appending(path: "Capture/\(name.cafName)"))
        return placed || (caf?.length ?? 0) > 0
    }

    static func record(_ name: SegmentName, in package: URL) throws -> FinalizeRecord? {
        try Sidecar.decode(Data(contentsOf: package.appending(path: "Capture/\(name.sidecarName)")))?.finalized
    }

    /// Opens `package` as the app does after a crash, checks that each segment has audio, and
    /// returns the session that the open recovered.
    static func reopened(_ package: URL, _ comment: String) async throws -> Session {
        let studio = try await Studio.open(package)
        await studio.rawSweep
        #expect(studio.takeError == nil, "\(comment)")
        #expect(studio.session.recording == nil, "\(comment)")
        #expect(studio.unplacedSegments == [], "\(comment)")
        for name in segments {
            #expect(hasAudio(name, session: studio.session, in: package), "\(name): \(comment)")
        }
        let session = studio.session
        await studio.settle()
        return session
    }

    /// C5: a stop save that fails after the finalize keeps every CAF, the take stays pending, and
    /// no sweep job starts.
    @Test func aFailedStopSaveKeepsEveryCAF() async throws {
        let take = try RawRemovalStopTests()
        let studio = try await Studio.open(take.url)
        let steps = RawRemovalStopTests.Steps()
        defer { steps.first.open() }
        let root = take.url.path
        defer { chmod(root, 0o755) }
        do {
            // The save of session.xml writes in the package root.
            try await take.recordAndStop(studio, steps: steps, beforeFinalize: { chmod(root, 0o555) })
            Issue.record("the stop did not throw")
        } catch StudioError.file(.writeFailed(_, let code)) {
            #expect(code == EACCES)
        }
        chmod(root, 0o755)

        await studio.rawSweep

        #expect(studio.pendingTake?.take == 1)
        #expect(steps.seen.isEmpty, "a sweep job started: \(steps.seen)")
        for name in Self.segments {
            let caf = try AVAudioFile(forReading: take.capture.appending(path: name.cafName))
            #expect(caf.length > 0, "\(name) keeps its CAF")
        }
        await studio.settle()
    }

    /// C4 (a): a crash after the finalize appended its records and before the save. The open
    /// finalizes the take again, and each sidecar decodes with a finalize record.
    @Test func aCrashBeforeTheStopSaveFinalizesAgainAtOpen() async throws {
        let package = try Self.take()
        let (url, copy) = (package.url, package.folder.url.appending(path: "Copy.dirigible"))
        try await offMainActor {
            let lock = try PackageLock(url)
            let outcome = completeTake(of: try Session(contentsOf: url), lock: lock, level: false) {
                _ throws(SessionFileError) in
                // The process dies here: the copy is the package at that instant.
                do { try FileManager.default.copyItem(at: url, to: copy) } catch { Issue.record(error) }
                throw .writeFailed(step: "crash", errno: EIO)
            }
            #expect(outcome.error == .file(.writeFailed(step: "crash", errno: EIO)))
        }
        let crashed = try Session(contentsOf: copy)
        #expect(crashed.recording?.take == 1, "the crash leaves the take pending")
        for name in Self.segments {
            #expect(try Self.record(name, in: copy) != nil, "\(name) has its record at the crash")
            #expect(Self.hasAudio(name, session: crashed, in: copy), "\(name) has audio at the crash")
        }

        for package in [url, copy] {
            _ = try await Self.reopened(package, "open of \(package.lastPathComponent)")
            for name in Self.segments {
                #expect(try Self.record(name, in: package) != nil, "\(name) in \(package.lastPathComponent)")
            }
        }
    }

    /// C4 (b): a crash after the save, before the record bytes reach the disk. Each segment is
    /// placed and keeps its CAF, and the open keeps each segment placed.
    @Test func aCrashThatDropsTheRecordBytesKeepsTheTakePlaced() async throws {
        let package = try Self.take()
        let url = package.url
        try await offMainActor {
            let outcome = completeTake(of: try Session(contentsOf: url), lock: try PackageLock(url), level: false) {
                session throws(SessionFileError) in try session.write(to: url)
            }
            #expect(outcome.error == nil)
        }
        for name in Self.segments {
            let record = try #require(try Self.record(name, in: url))
            let sidecar = package.capture.appending(path: name.sidecarName)
            let size = try #require(try FileManager.default.attributesOfItem(atPath: sidecar.path)[.size] as? Int)
            #expect(truncate(sidecar.path, off_t(size - Sidecar.encode(record).count)) == 0)
            #expect(try Self.record(name, in: url) == nil, "\(name) lost its record")
        }
        let copy = package.folder.url.appending(path: "Copy.dirigible")
        try FileManager.default.copyItem(at: url, to: copy)
        let crashed = try Session(contentsOf: copy)
        for name in Self.segments {
            let caf = try AVAudioFile(forReading: copy.appending(path: "Capture/\(name.cafName)"))
            #expect(caf.length > 0, "\(name) keeps its CAF at the crash")
            #expect(Self.hasAudio(name, session: crashed, in: copy), "\(name) has audio at the crash")
        }

        for package in [url, copy] {
            _ = try await Self.reopened(package, "open of \(package.lastPathComponent)")
        }
    }

    /// C4 (b2) and (c): a crash before the unlink of the CAF, and after the unlink before the
    /// flush of `Capture/`. Each open keeps each segment placed, with its sidecar record.
    @Test func aCrashBeforeOrAfterTheUnlinkKeepsTheTakePlaced() async throws {
        let package = try Self.take()
        let url = package.url
        let names = Self.segments
        let (beforeUnlink, afterUnlink) = (
            package.folder.url.appending(path: "BeforeUnlink.dirigible"),
            package.folder.url.appending(path: "AfterUnlink.dirigible")
        )
        try await offMainActor {
            let lock = try PackageLock(url)
            let outcome = completeTake(of: try Session(contentsOf: url), lock: lock, level: false) {
                session throws(SessionFileError) in try session.write(to: url)
            }
            #expect(outcome.error == nil)
            // The sweep flushed each sidecar here and did not unlink yet: the bytes on disk are the
            // bytes after the save.
            try FileManager.default.copyItem(at: url, to: beforeUnlink)
            let removable = removableCaptures(of: outcome.session, in: url)
            #expect(removable.map(\.name) == names)
            for candidate in removable {
                let read = RawRead(files: candidate.files, record: try #require(candidate.record))
                #expect(try removeRawCapture(candidate.name, of: outcome.session, in: url, read: read))
            }
            try FileManager.default.copyItem(at: url, to: afterUnlink)
        }
        for name in Self.segments {
            #expect(
                FileManager.default.fileExists(atPath: beforeUnlink.appending(path: "Capture/\(name.cafName)").path))
            #expect(
                !FileManager.default.fileExists(atPath: afterUnlink.appending(path: "Capture/\(name.cafName)").path))
        }

        for package in [url, beforeUnlink, afterUnlink] {
            let session = try await Self.reopened(package, "open of \(package.lastPathComponent)")
            #expect(session.files.count == 2, "\(package.lastPathComponent)")
            for name in Self.segments {
                #expect(try Self.record(name, in: package) != nil, "\(name) in \(package.lastPathComponent)")
            }
        }
    }
}
