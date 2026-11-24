import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The open of an archived package through `poolFileName` and the peak cache of the package jobs
/// (decision 0072, run criteria C10 and C14).
struct ArchivedMediaTests {
    /// The cache URL that a package job gets.
    enum CacheCase: CaseIterable {
        case writable
        case none
        /// A regular file at the folder path.
        case regularFile
        /// A folder that holds the entries of the WAVs and refuses new files.
        case readOnly
    }

    @Test func anArchivedPackageReadsItsFLACFiles() async throws {
        let fixture = try ArchiveFixture()
        var session = Session(sampleRate: ArchiveFixture.rate)
        let files = try Self.addFiles(to: &session, in: fixture)
        var before: [Peaks] = []
        for file in files { before.append(try await Self.peaks(of: file, in: fixture)) }

        _ = try archivePackage(&session, in: fixture.package, save: fixture.save)

        #expect(try fixture.names() == ["a.flac", "b.flac"])
        #expect(try checkMedia(session, package: fixture.package) == [:])
        for (file, wav) in zip(files, before) {
            let flac = try await Self.peaks(of: file, in: fixture)
            #expect(try flac.stamp == stampOnDisk(fixture.url("Clips/\(archivedPath(of: file.path)!)")))
            #expect(flac.frames == wav.frames && flac.levels == wav.levels, "the bins of \(file.path)")
        }
    }

    @Test(arguments: CacheCase.allCases)
    func eachJobRekeysThePeakCache(_ kind: CacheCase) async throws {
        let fixture = try ArchiveFixture()
        var session = Session(sampleRate: ArchiveFixture.rate)
        let files = try Self.addFiles(to: &session, in: fixture)
        let cache = fixture.folder.url.appending(path: "Peaks")
        var wavPeaks: [String: Peaks] = [:]
        for file in files {
            let peaks = try await Self.peaks(of: file, in: fixture)
            try PeakFile.write(peaks, path: file.path, in: cache)
            wavPeaks[file.path] = peaks
        }
        // 70,000 frames give 274 bins of 256 frames at level 0.
        #expect(try Self.states(session, fixture, cache) == ["a.wav": .hit(bins: 274), "b.wav": .hit(bins: 274)])
        switch kind {
        case .writable, .none: break
        case .regularFile:
            try FileManager.default.removeItem(at: cache)
            try Data("not a folder".utf8).write(to: cache)
        case .readOnly: #expect(chmod(cache.path, 0o555) == 0)
        }
        defer { chmod(cache.path, 0o755) }
        let url = kind == .none ? nil : cache
        let expected: PeakCacheState = kind == .writable ? .hit(bins: 274) : .miss

        let archived = try archivePackage(&session, in: fixture.package, cache: url, save: fixture.save)

        #expect(archived.converted == ["a.wav", "b.wav"] && archived.kept.isEmpty)
        #expect(try fixture.names() == ["a.flac", "b.flac"])
        #expect(try Self.states(session, fixture, cache) == ["a.wav": expected, "b.wav": expected])
        if kind == .writable {
            for file in files {
                let flac = try stampOnDisk(fixture.url("Clips/\(archivedPath(of: file.path)!)"))
                let read = PeakFile.read(
                    path: file.path, stamp: flac, channels: file.layout.channelCount, rate: ArchiveFixture.rate,
                    in: cache)
                #expect(read?.levels == wavPeaks[file.path]?.levels, "the bins of the WAV of \(file.path)")
            }
        }

        let restored = try unarchivePackage(&session, in: fixture.package, cache: url, save: fixture.save)

        #expect(restored.converted == ["a.wav", "b.wav"] && restored.kept.isEmpty)
        #expect(try fixture.names() == ["a.wav", "b.wav"])
        #expect(try Self.states(session, fixture, cache) == ["a.wav": expected, "b.wav": expected])
    }

    /// C10: a job of another process unlinks the WAV after its rename, between the resolve and
    /// the open, or between `open(2)` and `AVAudioFile`.
    @Test(arguments: [MediaOpenStep.resolved, .opened])
    func openMediaOpensTheFLACWhenAJobUnlinksTheWAV(_ step: MediaOpenStep) throws {
        let fixture = try ArchiveFixture()
        let file = try fixture.addWAV("a.wav", seed: 1)
        // A conversion that stops after its rename leaves both files.
        let stopped = try archiveClip(
            file, in: fixture.package, rate: ArchiveFixture.rate, after: { done, _ in done != .renamed })
        #expect(!stopped)
        #expect(poolFileName(file, in: fixture.package).form == .pool)
        let wav = fixture.url("Clips/a.wav")

        let opened = try openMedia(file, in: fixture.url(clipsFolderName), rate: ArchiveFixture.rate) { at in
            if at == step { unlink(wav.path) }
        }

        #expect(try fixture.names() == ["a.flac"], "the seam unlinked the WAV")
        #expect(opened.file?.url.lastPathComponent == "a.flac")
        #expect(opened.fault == nil)
        #expect(opened.stamp == (try stampOnDisk(fixture.url("Clips/a.flac"))))
    }

    /// C10: a job of another process converts the FLAC back after the resolve.
    @Test func openMediaOpensTheWAVWhenAJobUnlinksTheFLAC() throws {
        let fixture = try ArchiveFixture()
        let file = try fixture.addWAV("a.wav", seed: 1)
        #expect(try archiveClip(file, in: fixture.package, rate: ArchiveFixture.rate))
        #expect(poolFileName(file, in: fixture.package).form == .flac)

        let opened = try openMedia(file, in: fixture.url(clipsFolderName), rate: ArchiveFixture.rate) { at in
            if at == .resolved { _ = try? unarchiveClip(file, in: fixture.package, rate: ArchiveFixture.rate) }
        }

        #expect(try fixture.names() == ["a.wav"], "the seam converted the FLAC")
        #expect(opened.file?.url.lastPathComponent == "a.wav")
        #expect(opened.fault == nil)
        #expect(opened.stamp == (try stampOnDisk(fixture.url("Clips/a.wav"))))
    }

    /// A mono and a stereo pool WAV of 70,000 frames.
    static func addFiles(to session: inout Session, in fixture: ArchiveFixture) throws -> [AudioFile] {
        let files = [
            try fixture.addWAV("a.wav", frames: 70_000, seed: 1),
            try fixture.addWAV("b.wav", frames: 70_000, channels: 2, seed: 2),
        ]
        for file in files { try session.addFile(file) }
        return files
    }

    /// The peaks of the file that `openMedia` opens for `file`, with its stamp.
    static func peaks(of file: AudioFile, in fixture: ArchiveFixture) async throws -> Peaks {
        let opened = try openMedia(file, in: fixture.url(clipsFolderName), rate: ArchiveFixture.rate)
        let audio = try #require(opened.file)
        return try await computePeaks(audio, stamp: try #require(opened.stamp)) { .go }
    }

    static func states(_ session: Session, _ fixture: ArchiveFixture, _ cache: URL) throws -> [String: PeakCacheState] {
        Dictionary(
            uniqueKeysWithValues: try peakCacheStates(of: session, package: fixture.package, cache: cache).map {
                ($0.path, $0.state)
            })
    }
}

/// The size and the modification time of the file at `url`, as `stat(2)` gives them.
private func stampOnDisk(_ url: URL) throws -> FileStamp {
    var info = stat()
    guard stat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
    return FileStamp(
        size: Int64(info.st_size), seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
}
