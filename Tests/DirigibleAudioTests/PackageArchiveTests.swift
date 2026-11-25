import AVFoundation
import CryptoKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The package jobs of decision 0072: what the archive converts and keeps, a damaged source, the
/// repair of a mixed state, the refusals, and the 0071 readers of an archived take (run criteria
/// C6, C10, C13, C16, C21 (a), and C21 (c)).
struct PackageArchiveTests {
    @Test func theArchiveKeepsOtherFiles() throws {
        let fixture = try ArchiveFixture()
        var session = Session(sampleRate: ArchiveFixture.rate)
        try session.addFile(try fixture.addWAV("a.wav", seed: 1))
        try session.addFile(try fixture.addWAV("b.wav", bits: 16, seed: 2))
        // A pool entry that no track clip uses, as a file that only a bin holds.
        try session.addFile(try fixture.addWAV("d.wav", channels: 2, seed: 3))
        try fixture.write("Clips/c.caf", Data("not a WAV".utf8))
        try session.addFile(AudioFile(id: "c", path: "c.caf", layout: .mono, length: 10))
        try session.addFile(AudioFile(id: "gone", path: "gone.wav", layout: .mono, length: 10))
        try fixture.addWAV("stray.wav", seed: 4)
        try fixture.addSoleCopy("take1-1-1")
        try fixture.write("Capture/take2-1-1.caf", Data("a CAF that the 0071 gate keeps".utf8))
        try fixture.write("Capture/take2-1-1.sidecar", Data("a sidecar".utf8))
        try fixture.write("Capture/take2.anchor", Data("an anchor".utf8))
        _ = try fixture.save(session)
        let kept = try fixture.contents(of: ["Clips/b.wav", "Clips/c.caf", "Clips/stray.wav", "Clips/take1-1-1.wav"])
        let capture = try fixture.folderContents("Capture")

        let report = try archivePackage(&session, in: fixture.package, save: fixture.save)

        #expect(report.converted == ["a.wav", "d.wav"])
        #expect(report.kept == ["b.wav": .notArchivable, "c.caf": .notWAV, "gone.wav": .missing])
        #expect(
            try fixture.names() == ["a.flac", "b.wav", "c.caf", "d.flac", "stray.wav", "take1-1-1.wav"])
        #expect(try fixture.contents(of: Array(kept.keys)) == kept)
        #expect(try fixture.folderContents("Capture") == capture)
        #expect(session.archive == .flac)
        #expect(try fixture.stored().archive == .flac)
        #expect(
            unplacedSegments(wavBackedSegments(in: fixture.package), session: session).map(\.stem) == ["take1-1-1"],
            "the WAV-backed unplaced segment stays one")
    }

    @Test func anArchiveKeepsAShortWAVAndConvertsTheOthers() throws {
        let fixture = try ArchiveFixture()
        var session = Session(sampleRate: ArchiveFixture.rate)
        try session.addFile(try fixture.addWAV("a.wav", seed: 1))
        try session.addFile(try fixture.addWAV("short.wav", frames: 20_000, length: 30_000, seed: 2))
        let short = try fixture.contents(of: ["Clips/short.wav"])

        let report = try archivePackage(&session, in: fixture.package, save: fixture.save)

        #expect(report.converted == ["a.wav"])
        #expect(report.kept == ["short.wav": .damaged(frames: 20_000)])
        #expect(try fixture.contents(of: ["Clips/short.wav"]) == short)
        #expect(try fixture.names() == ["a.flac", "short.wav"])
        #expect(try fixture.stored().archive == .flac)
    }

    @Test func anUnarchiveKeepsEachDamagedFLACAndClearsTheAttribute() throws {
        let fixture = try ArchiveFixture()
        var session = Session(sampleRate: ArchiveFixture.rate)
        for (index, name) in ["whole", "half", "flipped"].enumerated() {
            try session.addFile(try fixture.addWAV("\(name).wav", frames: 150_000, seed: UInt64(index + 1)))
        }
        let whole = try wavData(fixture.url("Clips/whole.wav"))
        _ = try archivePackage(&session, in: fixture.package, save: fixture.save)
        let half = fixture.url("Clips/half.flac")
        let bytes = try Data(contentsOf: half)
        try bytes.prefix(bytes.count / 2).write(to: half)
        try flipByte(in: fixture.url("Clips/flipped.flac"))
        let damaged = try fixture.contents(of: ["Clips/half.flac", "Clips/flipped.flac"])

        let report = try unarchivePackage(&session, in: fixture.package, save: fixture.save)

        #expect(report.converted == ["whole.wav"])
        #expect(try wavData(fixture.url("Clips/whole.wav")) == whole)
        #expect(Set(report.kept.keys) == ["half.wav", "flipped.wav"])
        guard case .damaged(let frames) = report.kept["half.wav"] else {
            Issue.record("half.wav is not kept as damaged")
            return
        }
        #expect(frames < 150_000, "the decoded frames of the half FLAC")
        guard case .damaged = report.kept["flipped.wav"] else {
            Issue.record("flipped.wav is not kept as damaged")
            return
        }
        #expect(try fixture.contents(of: Array(damaged.keys)) == damaged)
        #expect(try fixture.names() == ["flipped.flac", "half.flac", "whole.wav"])
        #expect(session.archive == nil)
        #expect(try fixture.stored().archive == nil)
        #expect(!needsUnarchive(try fixture.stored()))
    }

    @Test func anIOFaultStopsTheUnarchiveAndKeepsEveryFile() throws {
        let fixture = try ArchiveFixture()
        var session = Session(sampleRate: ArchiveFixture.rate)
        for name in ["a", "b", "c"] { try session.addFile(try fixture.addWAV("\(name).wav", seed: 7)) }
        _ = try archivePackage(&session, in: fixture.package, save: fixture.save)
        let later = try fixture.contents(of: ["Clips/b.flac", "Clips/c.flac"])
        var seams = ArchiveSeams()
        var calls = 0
        seams.unarchive = { file, package, rate, isStopped throws(ClipArchiveFault) in
            calls += 1
            if calls == 2 { throw .read(file: archivedPath(of: file.path)!, errno: EIO) }
            return try unarchiveClip(file, in: package, rate: rate, isCancelled: isStopped)
        }

        #expect(throws: ArchiveFault.clip(.read(file: "b.flac", errno: EIO))) {
            try unarchivePackage(
                &session, also: [], in: fixture.package, progress: { _ in }, isStopped: { false },
                save: fixture.save, seams: seams)
        }
        #expect(try fixture.names() == ["a.wav", "b.flac", "c.flac"])
        #expect(try fixture.contents(of: Array(later.keys)) == later)
        #expect(session.archive == .flac)
        #expect(try fixture.stored().archive == .flac)
    }

    @Test func anUnarchiveRepairsAMixedState() throws {
        let fixture = try ArchiveFixture()
        var session = Session(sampleRate: ArchiveFixture.rate)
        let file = try fixture.addWAV("a.wav", seed: 1)
        try session.addFile(file)
        try session.addFile(try fixture.addWAV("b.wav", seed: 2))
        session.archive = .flac
        _ = try fixture.save(session)
        let wavs = try fixture.contents(of: ["Clips/a.wav", "Clips/b.wav"])

        let first = try unarchivePackage(&session, in: fixture.package, save: fixture.save)
        #expect(first.converted.isEmpty)
        #expect(try fixture.stored().archive == nil, "the attribute with every file a WAV goes")
        #expect(try fixture.contents(of: Array(wavs.keys)) == wavs)

        #expect(try archiveClip(file, in: fixture.package, rate: ArchiveFixture.rate))
        let before = try fixture.sessionFile()
        let second = try unarchivePackage(&session, in: fixture.package, save: fixture.save)
        #expect(second.converted == ["a.wav"])
        #expect(try fixture.names() == ["a.wav", "b.wav"])
        #expect(try fixture.sessionFile() == before, "no attribute to clear: no save")
    }

    @Test func aJobWithNothingToDoChangesNoFile() throws {
        let fixture = try ArchiveFixture()
        var session = Session(sampleRate: ArchiveFixture.rate)
        try session.addFile(try fixture.addWAV("a.wav", seed: 1))
        _ = try fixture.save(session)
        var before = try fixture.sessionFile()
        #expect(try unarchivePackage(&session, in: fixture.package, save: fixture.save).converted.isEmpty)
        #expect(try fixture.sessionFile() == before)

        _ = try archivePackage(&session, in: fixture.package, save: fixture.save)
        before = try fixture.sessionFile()
        let flac = try fixture.contents(of: ["Clips/a.flac"])
        #expect(try archivePackage(&session, in: fixture.package, save: fixture.save).converted.isEmpty)
        #expect(try fixture.sessionFile() == before)
        #expect(try fixture.contents(of: ["Clips/a.flac"]) == flac)
    }

    @Test func aPendingTakeRefusesTheArchive() throws {
        let fixture = try ArchiveFixture()
        var session = Session(sampleRate: ArchiveFixture.rate)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addFile(try fixture.addWAV("a.wav", seed: 1))
        try session.setRecording(Recording(take: 2, playheadFrame: 0, takeStartHostTimeNanos: 0, armedTracks: ["t1"]))
        _ = try fixture.save(session)
        let before = try fixture.sessionFile()

        #expect(throws: ArchiveFault.pendingTake) {
            try archivePackage(&session, in: fixture.package, save: fixture.save)
        }
        #expect(try fixture.names() == ["a.wav"])
        #expect(try fixture.sessionFile() == before)
        #expect(session.archive == nil)
    }

    @Test func theFavoritesStoreOfTheProcessIsNeverArchived() throws {
        let fixture = try ArchiveFixture()
        let store = fixture.folder.url.appending(path: "Store/Favorites.dirigible")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let link = fixture.folder.url.appending(path: "Link.dirigible")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: store)
        var seams = ArchiveSeams()
        seams.environment = ["DIRIGIBLE_FAVORITES": store.path]
        var session = Session(sampleRate: ArchiveFixture.rate)

        for path in [store, link] {
            #expect(throws: ArchiveFault.favoritesStore) {
                try archivePackage(
                    &session, in: path, progress: { _ in }, isStopped: { false }, save: fixture.save, seams: seams)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.path).isEmpty)

        try session.addFile(try fixture.addWAV("a.wav", seed: 1))
        let report = try archivePackage(
            &session, in: fixture.package, progress: { _ in }, isStopped: { false }, save: fixture.save, seams: seams)
        #expect(report.converted == ["a.wav"], "another path archives")
    }

    @Test func anUnarchiveConvertsTheFLACOfAWAVBackedSegment() throws {
        let fixture = try ArchiveFixture()
        var session = Session(sampleRate: ArchiveFixture.rate)
        let segment = try fixture.addSoleCopy("take1-1-1")
        let data = try wavData(fixture.url("Clips/take1-1-1.wav"))
        #expect(try archiveClip(segment, in: fixture.package, rate: ArchiveFixture.rate))
        let other = try fixture.addWAV("x.wav", seed: 9)
        #expect(try archiveClip(other, in: fixture.package, rate: ArchiveFixture.rate))
        let top = try fixture.contents(of: ["Clips/x.flac"])
        session.archive = .flac
        _ = try fixture.save(session)

        let report = try unarchivePackage(&session, in: fixture.package, save: fixture.save)

        #expect(report.converted == ["take1-1-1.wav"])
        #expect(try wavData(fixture.url("Clips/take1-1-1.wav")) == data)
        #expect(try fixture.names() == ["take1-1-1.wav", "x.flac"])
        #expect(try fixture.contents(of: ["Clips/x.flac"]) == top, "a FLAC with no pool entry and no record stays")
        #expect(unplacedSegments(wavBackedSegments(in: fixture.package), session: session).map(\.stem) == ["take1-1-1"])
        #expect(try fixture.stored().archive == nil)
    }

    /// C21 (a): the archive converts the clip of a placed take whose CAF is gone, and the 0071
    /// predicates still find that FLAC as the only copy of the take audio.
    @Test func aSoleCopyTakeStaysReachable() throws {
        let (take, finalized) = try RawRemovalGateTests.twoClockTake(bows: (0, 0))
        let (first, second) = (RawRemovalGateTests.first, RawRemovalGateTests.second)
        try FileManager.default.removeItem(at: take.capture.appending(path: first.cafName))
        func save(_ session: Session) throws(SessionFileError) -> URL {
            try session.write(to: take.url)
            return take.url
        }
        var session = finalized
        _ = try save(session)
        #expect(wavBackedSegments(in: take.url) == [first])

        let report = try archivePackage(&session, in: take.url, save: save)

        #expect(report.converted == ["take1-1-1.wav", "take1-2-1.wav"])
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: take.url.appending(path: "Clips").path).sorted()
                == ["take1-1-1.flac", "take1-2-1.flac"])
        #expect(wavBackedSegments(in: take.url) == [first])
        #expect(soleCopyWAVs(in: take.url) == ["take1-1-1.wav"])
        #expect(rawCaptures(of: session, in: take.url) == [second: .archived], "the CAF of the first is gone")
    }

    /// C10 raw part: a placed take whose clip is a FLAC that an unarchive kept as damaged (no
    /// attribute) gets `.archived` and keeps its CAF. The other track of the take loses its CAF.
    @Test func aTakeWhoseClipIsADamagedFLACKeepsItsCAF() throws {
        let (take, session) = try RawRemovalGateTests.twoClockTake(bows: (0, 0))
        let (first, second) = (RawRemovalGateTests.first, RawRemovalGateTests.second)
        #expect(try archiveClip(#require(session.files["take1-1-1"]), in: take.url, rate: 48_000))
        let flac = take.url.appending(path: "Clips/take1-1-1.flac")
        let whole = try Data(contentsOf: flac)
        try whole.prefix(whole.count / 2).write(to: flac)

        #expect(rawCaptures(of: session, in: take.url) == [first: .archived, second: .removable])
        #expect(removableCaptures(of: session, in: take.url).map { $0.name } == [second])
        removeRecordedRawCaptures(of: session, in: take.url) { .disabled }

        #expect(FileManager.default.fileExists(atPath: take.capture.appending(path: first.cafName).path))
        #expect(!FileManager.default.fileExists(atPath: take.capture.appending(path: second.cafName).path))
        #expect(try Data(contentsOf: flac) == whole.prefix(whole.count / 2), "the FLAC stays as it was")
    }
}

/// A package for the package jobs: clip WAVs of seeded noise, written with no session file until
/// a test saves one.
final class ArchiveFixture {
    static let rate = 48_000

    let folder: TemporaryFolder
    let package: URL

    init() throws {
        folder = try TemporaryFolder()
        package = folder.url.appending(path: "Show.dirigible")
        try FileManager.default.createDirectory(
            at: package.appending(path: clipsFolderName), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: package.appending(path: captureFolderName), withIntermediateDirectories: true)
    }

    func url(_ path: String) -> URL { package.appending(path: path) }

    /// Writes `Clips/<path>`: `frames` frames of noise from `seed` at `rate`, 24-bit through the clip
    /// writer, or 16-bit. Returns its pool entry, of `length` frames (default `frames`); the caller
    /// adds it.
    @discardableResult
    func addWAV(
        _ path: String, frames: Int = 30_000, channels: Int = 1, bits: Int = 24, length: Int? = nil,
        rate: Int = ArchiveFixture.rate, seed: UInt64
    ) throws -> AudioFile {
        let url = url("\(clipsFolderName)/\(path)")
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(channels)))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        var state = seed
        for channel in 0..<channels {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<frames {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                samples[frame] = Float(Int32(truncatingIfNeeded: state >> 40) - 8_388_608) / 8_388_608
            }
        }
        if bits == 24 {
            let writer = try ClipWriter(url: url, file: path, format: format)
            try writer.write(buffer)
            try writer.close()
        } else {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: false,
                    AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                ])
            try file.write(from: buffer)
        }
        return AudioFile(
            id: FileID(path), path: path, layout: try #require(ChannelLayout(channelCount: channels)),
            length: Frames(length ?? frames))
    }

    /// The WAV-backed segment `stem` of decision 0071: `Clips/<stem>.wav`, and a sidecar with a
    /// finalize record and no CAF. No pool entry names it. Returns an entry for the clip calls.
    @discardableResult
    func addSoleCopy(_ stem: String) throws -> AudioFile {
        let file = try addWAV("\(stem).wav", seed: 11)
        let record = FinalizeRecord(cafFrames: 30_000, sourceRate: 48_000, conversionGain: try #require(Gain(dB: 0)))
        try write(
            "\(captureFolderName)/\(stem).sidecar", Sidecar.encode(TakePackage.header()) + Sidecar.encode(record))
        return file
    }

    func write(_ path: String, _ data: Data) throws { try data.write(to: url(path)) }

    func save(_ session: Session) throws(SessionFileError) -> URL {
        try session.write(to: package)
        return package
    }

    func stored() throws -> Session { try Session(contentsOf: package) }

    /// The bytes and the modification time of `session.xml`.
    func sessionFile() throws -> Data {
        let url = url("session.xml")
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return try Data(contentsOf: url) + Data("\(modified?.timeIntervalSince1970 ?? 0)".utf8)
    }

    /// The names in `Clips/`, sorted.
    func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url(clipsFolderName).path).sorted()
    }

    func contents(of paths: [String]) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: paths.map { try ($0, Data(contentsOf: url($0))) })
    }

    func folderContents(_ folder: String) throws -> [String: Data] {
        try contents(of: FileManager.default.contentsOfDirectory(atPath: url(folder).path).map { "\(folder)/\($0)" })
    }
}
