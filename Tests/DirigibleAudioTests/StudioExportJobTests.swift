import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The export job of Studio (export run criteria 18, 22 to 25): the snapshot, settle, the files
/// and descriptors, the media question and report, the thread, the QoS, and the progress.
@MainActor
struct StudioExportJobTests {
    /// The open descriptors of this process that point at `url`.
    nonisolated static func descriptors(to url: URL) -> Int {
        guard let target = realpath(url.path, nil) else { return 0 }
        defer { free(target) }
        let path = String(cString: target)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return (0..<getdtablesize()).count { descriptor in
            fcntl(descriptor, F_GETPATH, &buffer) == 0 && String(cString: &buffer) == path
        }
    }

    /// An edit at chunk 2 is saved; the file has the audio of the start (no track gain).
    @Test func anEditDuringAnExportKeepsTheSnapshot() async throws {
        let fixture = try await ExportStudioFixture.make()
        let gate = Gate()
        let studio = try await fixture.open(seam: ChunkSeam(at: [2: { gate.waitOnce() }]))
        let (source, options, out, url) = (fixture.source, fixture.options, fixture.out, fixture.package.url)
        let export = Task { try await studio.export(source, options, to: out, replacing: nil) }
        await gate.entered()

        try studio.edit { session throws(SessionError) in try session.setGain(Gain(dB: -20)!, track: "t1") }
        await until(limit: .seconds(10), "the edit was not saved") {
            (try? Session(contentsOf: url))?.track("t1")?.gain == Gain(dB: -20)
        }
        gate.open()

        _ = try await export.value
        try await ExportStudioFixture.expectTheExport(at: fixture.out)
    }

    @Test func settleCancelsTheExport() async throws {
        let fixture = try await ExportStudioFixture.make()
        let studio = try await fixture.open(seam: ChunkSeam(pause: longChunk))
        let (source, options, out) = (fixture.source, fixture.options, fixture.out)
        let export = Task { try await studio.export(source, options, to: out, replacing: nil) }
        await until(limit: .seconds(10), "the export did not start") { studio.exportProgress != nil }

        await studio.settle()

        #expect(studio.exportProgress == nil)
        #expect(try fixture.temporaryFiles() == [])
        #expect(!FileManager.default.fileExists(atPath: out.path))
        await #expect(throws: StudioError.export(.cancelled)) { try await export.value }
    }

    /// Starts an export, closes the studio during it, and drops the studio.
    func exportAndClose(_ fixture: ExportStudioFixture) async throws {
        let studio = try await fixture.open(seam: ChunkSeam(pause: longChunk))
        let (source, options, out) = (fixture.source, fixture.options, fixture.out)
        let export = Task { try await studio.export(source, options, to: out, replacing: nil) }
        await until(limit: .seconds(10), "the export did not start") { studio.exportProgress != nil }
        await studio.settle()
        await #expect(throws: StudioError.export(.cancelled)) { try await export.value }
    }

    @Test func aReopenAfterACloseDuringAnExportWorks() async throws {
        let fixture = try await ExportStudioFixture.make()
        try await exportAndClose(fixture)

        let studio = try await Studio.open(fixture.package.url)

        #expect(studio.session.track("t1")?.clips.count == 1)
    }

    @Test func anExportClosesItsFiles() async throws {
        let fixture = try await ExportStudioFixture.make()
        let clip = fixture.package.url.appending(path: "\(clipsFolderName)/f1.wav")
        // Control: the count sees a descriptor that a handle holds.
        let handle = try FileHandle(forReadingFrom: clip)
        #expect(Self.descriptors(to: clip) == 1)
        try handle.close()
        let studio = try await fixture.open()
        #expect(Self.descriptors(to: clip) == 0)

        _ = try await studio.export(fixture.source, fixture.options, to: fixture.out, replacing: nil)

        #expect(Self.descriptors(to: clip) == 0)
    }

    /// t1: `c1` (f1, present) at 0, `c4` (f4, missing) at 480 000, `c2` (f2, missing) at
    /// 700 000. t2: `c3` (f3, missing) at 0. The source is 0..<600 000 on t1.
    @Test func theMediaQuestionListsOnlyTheFilesInTheRange() async throws {
        let fixture = try await ExportStudioFixture.make { package in
            for (file, clip, start) in [("f4", "c4", 480_000), ("f2", "c2", 700_000), ("f3", "c3", 0)] {
                try package.session.addFile(
                    AudioFile(id: FileID(file), path: "\(file).wav", layout: .mono, length: 60_000))
                if file == "f3" { try package.session.addTrack("t2", name: "t2", layout: .mono) }
                try package.session.place(
                    Clip(id: ClipID(clip), file: FileID(file), start: Frames(start), offset: 0, length: 60_000),
                    on: file == "f3" ? "t2" : "t1")
            }
        }
        let studio = try await fixture.open()

        let faults = await studio.exportFaults(try #require(ExportSource(range: 0..<600_000, tracks: ["t1"])))

        #expect(faults == ["f4": .missing])
    }

    /// Chunk 2 deletes the file of `c2` (t2, from 336 000). The question saw no fault.
    @Test func theReportNamesAFileThatWentMissingDuringTheExport() async throws {
        let fixture = try await ExportStudioFixture.make { package in
            try package.addFile("f2", channels: [ExportTests.tone(frames: 144_000)])
            try package.addTrack("t2", clip: "c2", file: "f2", start: 336_000, offset: 0, length: 144_000)
        }
        let f2 = fixture.package.url.appending(path: "\(clipsFolderName)/f2.wav")
        let studio = try await fixture.open(seam: ChunkSeam(at: [2: { unlink(f2.path) }]))
        #expect(await studio.exportFaults(fixture.source) == [:])

        let faults = try await studio.export(fixture.source, fixture.options, to: fixture.out, replacing: nil)

        #expect(faults == ["f2": .missing])
    }

    @Test func theExportWritesOffTheMainThread() async throws {
        let fixture = try await ExportStudioFixture.make()
        let seam = ChunkSeam()
        let studio = try await fixture.open(seam: seam)

        _ = try await studio.export(fixture.source, fixture.options, to: fixture.out, replacing: nil)

        // 10 chunks and the cancel check after the close.
        #expect(seam.calls == 11)
        #expect(seam.onMain.allSatisfy { !$0 })
    }

    @Test func theExportStaysAtUtilityWhileAUserInitiatedCallerWaits() async throws {
        let fixture = try await ExportStudioFixture.make()
        let seam = ChunkSeam(pause: 0.01)
        let studio = try await fixture.open(seam: seam)
        let (source, options, out) = (fixture.source, fixture.options, fixture.out)

        let caller = Task(priority: .userInitiated) {
            try await studio.export(source, options, to: out, replacing: nil)
        }
        _ = try await caller.value

        // 10 chunks and the cancel check after the close.
        #expect(seam.calls == 11)
        #expect(seam.qos.allSatisfy { $0 == QOS_CLASS_UTILITY }, "\(seam.qos.map(\.rawValue))")
        #expect(seam.priorities.allSatisfy { $0 == .utility }, "\(seam.priorities)")
    }

    /// The gate holds the export at chunk 3, after the progress calls of chunks 1 and 2, so the
    /// poll cannot miss the progress between two main-actor turns of a full suite.
    @Test func progressShowsDuringTheExport() async throws {
        let fixture = try await ExportStudioFixture.make()
        let gate = Gate()
        let studio = try await fixture.open(seam: ChunkSeam(at: [3: { gate.waitOnce() }]))
        let (source, options, out) = (fixture.source, fixture.options, fixture.out)
        let export = Task { try await studio.export(source, options, to: out, replacing: nil) }
        await gate.entered()

        await until(limit: .seconds(10), "no progress showed") { (studio.exportProgress ?? 0) > 0 }

        gate.open()
        _ = try await export.value
    }

    /// A progress hop of an export that ended changes nothing: not after its end, and not in
    /// the next export. The first export makes 11 cancel checks (10 chunks and the check after
    /// the close), so the gate holds the first chunk of the second export.
    @Test func aLateProgressDoesNotComeBack() async throws {
        let fixture = try await ExportStudioFixture.make()
        let gate = Gate()
        let studio = try await fixture.open(seam: ChunkSeam(at: [12: { gate.waitOnce() }]))
        _ = try await studio.export(fixture.source, fixture.options, to: fixture.out, replacing: nil)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(studio.exportProgress == nil)
        let (source, options) = (fixture.source, fixture.options)
        let second = fixture.package.folder.url.appending(path: "second.wav")
        let export = Task { try await studio.export(source, options, to: second, replacing: nil) }
        await gate.entered()
        let number = try #require(studio.exportJob?.number)

        studio.exportProgressed(number - 1, 0.9)

        #expect(studio.exportProgress == 0)
        gate.open()
        _ = try await export.value
    }

    /// A held autosave keeps `settle()` in its write wait. Settle holds export A at chunk 2
    /// until it begins, then cancels A. When A throws, its caller starts export B at once, while
    /// settle still runs. After settle, no file of A or B exists.
    @Test func anExportDuringSettleIsBusy() async throws {
        let fixture = try await ExportStudioFixture.make()
        let (chunk, save) = (Gate(), Gate())
        let studio = try await fixture.open(seam: ChunkSeam(at: [2: { chunk.waitOnce() }]))
        studio.environment.saveSession = { session, lock throws(SessionFileError) in
            save.waitOnce()
            return try session.write(under: lock)
        }
        try studio.edit { session throws(SessionError) in try session.setGain(Gain(dB: -6)!, track: "t1") }
        await save.entered()
        let (source, options, out) = (fixture.source, fixture.options, fixture.out)
        let second = fixture.package.folder.url.appending(path: "second.wav")
        let pair = Task { () -> StudioError? in
            _ = try? await studio.export(source, options, to: out, replacing: nil)
            do throws(StudioError) {
                _ = try await studio.export(source, options, to: second, replacing: nil)
            } catch {
                return error
            }
            return nil
        }
        await chunk.entered()
        let settle = Task { await studio.settle() }
        await until(limit: .seconds(10), "settle did not begin") { studio.settling }
        chunk.open()

        #expect(await pair.value == StudioError.busy)
        save.open()
        await settle.value

        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(try fixture.temporaryFiles() == [])
    }
}
