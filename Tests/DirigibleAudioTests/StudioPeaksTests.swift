import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A package with track `t1` on `mic` and clip `c1` of pool file `f1`: 600,000 frames of a 0.5
/// tone (3 compute blocks). The cache folder is next to the package. The package is written
/// off the main actor (learning 9a203ff).
final class PeakPackage: @unchecked Sendable {
    let package: MixPackage
    let cache: URL
    var url: URL { package.url }
    static let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!

    init(files: [FileID] = ["f1"]) throws {
        package = try MixPackage()
        cache = package.folder.url.appending(path: "Peaks")
        let tone = sine(seconds: 12.5, rate: 48_000, frequency: 375)
        for file in files { try package.addFile(file, channels: [tone]) }
        try package.addTrack("t1", clip: "c1", file: files[0], start: 0, offset: 0, length: 600_000)
        try package.session.setRoute(Route(deviceUID: "mic", channels: .mono(1)), track: "t1")
        try package.session.write(to: package.url)
    }

    static func make(files: [FileID] = ["f1"]) async throws -> PeakPackage {
        try await Task.detached { try PeakPackage(files: files) }.value
    }

    func wav(_ id: FileID) -> URL { url.appending(path: "Clips/\(id.rawValue).wav") }

    func cacheFiles() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? [] }

    /// Opens a Studio with the cache folder (or none), the test HAL, and `hook` before each block.
    @MainActor
    func studio(
        at url: URL? = nil, cache: Bool = true, hook: @escaping @Sendable () async -> Void = {}
    ) async throws -> Studio {
        let studio = try await Studio.open(url ?? self.url, peakCache: cache ? self.cache : nil)
        studio.environment = .test(TestHAL([Self.mic]))
        studio.environment.beforePeakBlock = { _ in await hook() }
        return studio
    }

    /// Writes 600,000 frames of `level` DC over the WAV of `id`: the same length, another mtime.
    func rewrite(_ id: FileID, level: Float = 0.25) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 600_000))
        buffer.frameLength = 600_000
        buffer.floatChannelData![0].update(repeating: level, count: 600_000)
        let writer = try ClipWriter(url: wav(id), file: "\(id.rawValue).wav", format: format)
        try writer.write(buffer)
        try writer.close()
    }
}

@MainActor
func peaksOf(_ studio: Studio, _ id: FileID) -> Peaks? {
    if case .ready(let peaks) = studio.peaks[id] { return peaks }
    return nil
}

/// Waits until the peaks of `id` are ready, with a limit of 30 s: the pass hops to the main actor
/// at each file and block, and the window tests of the suite hold the main actor.
@MainActor
func waitForPeaks(_ studio: Studio, _ id: FileID = "f1", limit: Duration = .seconds(30)) async -> Peaks? {
    await until(limit: limit, "the peaks of \(id) are not ready") { peaksOf(studio, id) != nil }
    return peaksOf(studio, id)
}

/// The Studio peak loader of decision 0017 (timeline-view criteria 3, 6, 7, 22, and 23). The
/// tests run one at a time: in parallel, their package writes slowed the timed tests of other suites.
@Suite(.serialized)
struct StudioPeaksTests {
    @Test @MainActor func aFileWithNoCacheComputesAndWritesOneCacheFile() async throws {
        let fixture = try await PeakPackage.make()
        let blocks = StepCounter()
        let studio = try await fixture.studio { _ = blocks.next() }

        let peaks = try #require(await waitForPeaks(studio))

        #expect(peaks.frames == 600_000)
        #expect(abs(Int(peaks.levels[0][10].peak) - 32767) <= 33)
        #expect(blocks.calls == 3)
        let files = fixture.cacheFiles()
        #expect(files.count == 1 && files[0].hasPrefix("f1.wav-") && files[0].hasSuffix(".peaks"), "\(files)")
    }

    @Test @MainActor func aSecondStudioLoadsWithNoCompute() async throws {
        let fixture = try await PeakPackage.make()
        var first: Studio? = try await fixture.studio()
        let computed = try #require(await waitForPeaks(first!))
        await first?.settle()
        first = nil

        let blocks = StepCounter()
        let second = try await fixture.studio { _ = blocks.next() }

        #expect(await waitForPeaks(second) == computed)
        #expect(blocks.calls == 0)
    }

    /// Code gate 1 item 2: a cache hit marks the cache file as used, so the launch prune of
    /// unused files keeps it.
    @Test @MainActor func aCacheHitMarksTheCacheFileUsed() async throws {
        let fixture = try await PeakPackage.make()
        var first: Studio? = try await fixture.studio()
        _ = try #require(await waitForPeaks(first!))
        await first?.settle()
        first = nil
        let file = fixture.cache.appending(path: try #require(fixture.cacheFiles().first))
        try PeakFileTests.age(file, days: 100)

        let second = try await fixture.studio()
        _ = try #require(await waitForPeaks(second))

        let modified = try #require(
            try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        #expect(modified > .now.addingTimeInterval(-3600), "\(modified)")
        await second.settle()
    }

    @Test @MainActor func aRewrittenWavComputesAgain() async throws {
        let fixture = try await PeakPackage.make()
        var first: Studio? = try await fixture.studio()
        _ = await waitForPeaks(first!)
        await first?.settle()
        first = nil
        try fixture.rewrite("f1")

        let blocks = StepCounter()
        let second = try await fixture.studio { _ = blocks.next() }
        let peaks = try #require(await waitForPeaks(second))

        #expect(peaks.levels[0][10] == PeakColumn(peak: 16384, rms: 16384))
        #expect(blocks.calls == 3)
        #expect(fixture.cacheFiles().count == 2)
    }

    @Test @MainActor func aMissingWavIsUnavailableAndWritesNothing() async throws {
        let fixture = try await PeakPackage.make()
        try FileManager.default.removeItem(at: fixture.wav("f1"))

        let studio = try await fixture.studio()

        await until(limit: .seconds(30), "f1 is not unavailable") { studio.peaks["f1"] == .unavailable }
        #expect(studio.missingMedia == ["f1": .missing])
        #expect(fixture.cacheFiles() == [])
    }

    @Test @MainActor func aShortWavGivesItsRealFrames() async throws {
        let fixture = try await PeakPackage.make()
        let real = try fixture.package.truncate("f1", toBytes: 900_000)

        let peaks = try #require(await waitForPeaks(try await fixture.studio()))

        #expect(real > 0 && real < 600_000)
        #expect(peaks.frames == Frames(real))
    }

    /// Probe F4b: `FileManager.copyItem` keeps the size and the mtime of each WAV.
    @Test @MainActor func aCopiedPackageLoadsWithNoCompute() async throws {
        let fixture = try await PeakPackage.make()
        var first: Studio? = try await fixture.studio()
        _ = await waitForPeaks(first!)
        await first?.settle()
        first = nil
        let copy = fixture.package.folder.url.appending(path: "Copy.dirigible")
        try FileManager.default.copyItem(at: fixture.url, to: copy)

        let blocks = StepCounter()
        let studio = try await fixture.studio(at: copy) { _ = blocks.next() }

        #expect(await waitForPeaks(studio) != nil)
        #expect(blocks.calls == 0)
    }

    /// An edit that removes a file keeps its entry, so the undo finds it with no compute.
    @Test @MainActor func anUndoThatBringsAFileBackFindsItsEntry() async throws {
        let fixture = try await PeakPackage.make()
        let blocks = StepCounter()
        let studio = try await fixture.studio { _ = blocks.next() }
        let peaks = try #require(await waitForPeaks(studio))
        try studio.edit { session throws(SessionError) in
            try session.removeTrack("t1")
            try session.removeFile("f1")
        }
        #expect(studio.peaks["f1"] == .ready(peaks))

        try studio.undo()
        try await Task.sleep(for: .milliseconds(200))

        #expect(studio.peaks["f1"] == .ready(peaks))
        #expect(blocks.calls == 3)
    }

    /// A redo, and an undo, that bring back a file that changed on disk start a pass.
    @Test @MainActor func aRedoThatBringsTheFilesBackIsReady() async throws {
        let fixture = try await PeakPackage.make(files: ["f1", "f2"])
        let studio = try await fixture.studio()
        _ = await waitForPeaks(studio, "f2")
        let f2 = try #require(studio.session.files["f2"])
        try studio.edit { session throws(SessionError) in try session.removeFile("f2") }
        try studio.edit { session throws(SessionError) in try session.addFile(f2) }
        try studio.undo()
        await until(limit: .seconds(30), "the pass of the undo did not end") { studio.peakLoad.pass == nil }
        try fixture.rewrite("f2")

        try studio.redo()

        await until(limit: .seconds(30), "f2 has the new peaks") {
            peaksOf(studio, "f2")?.levels[0][10] == PeakColumn(peak: 16384, rms: 16384)
        }

        // An undo of the add removes f2; an undo of the removal brings it back.
        try studio.undo()
        await until(limit: .seconds(30), "the pass of the undo did not end") { studio.peakLoad.pass == nil }
        try fixture.rewrite("f2", level: 0.125)
        try studio.undo()

        await until(limit: .seconds(30), "f2 has the peaks of the last rewrite") {
            peaksOf(studio, "f2")?.levels[0][10] == PeakColumn(peak: 8192, rms: 8192)
        }
    }

    /// A track rename keeps the pool files, so it starts no pass. The WAV changed before the
    /// edit, so a pass would compute.
    @Test @MainActor func anEditWithTheSameFilesStartsNoPass() async throws {
        let fixture = try await PeakPackage.make()
        let blocks = StepCounter()
        let studio = try await fixture.studio { _ = blocks.next() }
        _ = await waitForPeaks(studio)
        try fixture.rewrite("f1")

        try studio.edit { session throws(SessionError) in try session.renameTrack("t1", to: "Host") }
        try await Task.sleep(for: .milliseconds(300))

        #expect(blocks.calls == 3)
    }

    /// The command-line front end opens a Studio with no cache folder.
    @Test @MainActor func aStudioWithNoCacheFolderComputesNothing() async throws {
        let fixture = try await PeakPackage.make(files: ["f1", "f2"])
        let blocks = StepCounter()
        let studio = try await fixture.studio(cache: false) { _ = blocks.next() }
        try studio.edit { session throws(SessionError) in try session.removeFile("f2") }
        try studio.undo()
        studio.loadPeaks()
        try await Task.sleep(for: .milliseconds(300))

        #expect(studio.peaks == [:])
        #expect(blocks.calls == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.cache.path))
    }

    /// Every write error of the cache has one result: the peaks stay in memory. The package does
    /// not change.
    @Test @MainActor func aCacheWriteErrorKeepsThePeaksInMemory() async throws {
        let fixture = try await PeakPackage.make()
        try FileManager.default.createDirectory(at: fixture.cache, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.cache.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.cache.path) }
        let studio = try await fixture.studio()
        // The open adds the lock file; the pass has not run yet.
        let names = try FileManager.default.subpathsOfDirectory(atPath: fixture.url.path).sorted()
        let xml = try Data(contentsOf: fixture.url.appending(path: "session.xml"))

        #expect(await waitForPeaks(studio)?.frames == 600_000)
        #expect(fixture.cacheFiles() == [])
        #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.url.path).sorted() == names)
        #expect(try Data(contentsOf: fixture.url.appending(path: "session.xml")) == xml)
    }

    /// The pass opens each file with `openMedia`, so it gives the faults of `checkMedia`.
    @Test @MainActor func thePassAndCheckMediaGiveTheSameFaults() async throws {
        let fixture = try await PeakPackage.make(files: ["f1", "gone", "short", "rate"])
        let studio = try await fixture.studio()
        for id: FileID in ["f1", "gone", "short", "rate"] { _ = await waitForPeaks(studio, id) }
        #expect(studio.missingMedia == [:])
        try FileManager.default.removeItem(at: fixture.wav("gone"))
        let real = try fixture.package.truncate("short", toBytes: 900_000)
        let other = try MixPackage(sampleRate: 44_100)
        try other.addFile("rate", channels: [[Float](repeating: 0.25, count: 600_000)])
        try FileManager.default.removeItem(at: fixture.wav("rate"))
        try FileManager.default.copyItem(at: other.url.appending(path: "Clips/rate.wav"), to: fixture.wav("rate"))

        studio.loadPeaks()

        await until(limit: .seconds(30), "the pass did not reach each file") {
            studio.peaks["gone"] == .unavailable && studio.peaks["rate"] == .unavailable
                && peaksOf(studio, "short")?.frames == Frames(real)
        }
        let faults = try checkMedia(studio.session, package: fixture.url)
        #expect(faults == ["gone": .missing, "short": .short(Frames(real)), "rate": .unreadable])
        #expect(studio.missingMedia == faults)
        #expect(peaksOf(studio, "f1") != nil)
    }

    /// Plan gate 1: the main actor never reads a WAV. The `peakRead` step runs on the thread of
    /// each read: the file start (the open and the cache read) and each of the 3 block reads.
    @Test @MainActor func theComputeRunsOffTheMainThread() async throws {
        let fixture = try await PeakPackage.make()
        let (onMain, reads) = (StepCounter(), StepCounter())
        let studio = try await fixture.studio()
        studio.environment.peakRead = {
            _ = reads.next()
            if pthread_main_np() != 0 { _ = onMain.next() }
        }

        #expect(await waitForPeaks(studio) != nil)
        #expect(reads.calls == 4)
        #expect(onMain.calls == 0)
    }

    /// The pass resolves the package path at each file start. The hook of the first block of
    /// the first file moves the package on its volume.
    @Test @MainActor func renameDuringAPass() async throws {
        let fixture = try await PeakPackage.make(files: ["f1", "f2"])
        let moved = fixture.package.folder.url.appending(path: "Moved.dirigible")
        let (from, blocks) = (fixture.url, StepCounter())
        let studio = try await fixture.studio {
            _ = blocks.next()
            if blocks.calls == 1 { try? FileManager.default.moveItem(at: from, to: moved) }
        }

        _ = await waitForPeaks(studio, "f1")
        _ = await waitForPeaks(studio, "f2")

        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(studio.missingMedia == [:])
    }
}
