import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The export of one file for each part as one Studio job (run 2026-10-28-chapter-export-files,
/// criteria C10 and C11): a take, Cancel, and `settle()` stop the whole set.
@MainActor
struct StudioExportPartsTests {
    static let options = ExportOptions(format: .wav(.bits24), layout: .stereo, rate: .session)
    static let range: Range<Frames> = 0..<480_000

    /// The 10 s tone of `ExportStudioFixture` with a chapter at each second: 10 parts of 1 s.
    static func tenParts() async throws -> ExportStudioFixture {
        try await ExportStudioFixture.make { package in
            for second in 0..<10 {
                try package.session.setMarker(
                    Marker(
                        id: MarkerID("c\(second)"), name: "c\(second)", position: Frames(second * 48_000),
                        kind: .chapter))
            }
        }
    }

    static func targets(_ studio: Studio, _ fixture: ExportStudioFixture) -> [URL] {
        exportPartTargets(
            studio.session, range: range, by: .chapters, options: options, folder: fixture.package.folder.url,
            stem: "Ep"
        ).targets.map(\.url)
    }

    static func startSet(_ studio: Studio, _ fixture: ExportStudioFixture) -> Task<ExportPartsResult, any Error> {
        let folder = fixture.package.folder.url
        return Task {
            try await studio.export(
                ExportSource(range: range)!, by: .chapters, options: options, folder: folder, stem: "Ep",
                replacing: [:])
        }
    }

    /// The stop of a set that threw `.exportParts(.stopped(_))`; nil after another end.
    static func stop(of export: Task<ExportPartsResult, any Error>) async -> ExportPartsStop? {
        let error = await #expect(throws: StudioError.self) { try await export.value }
        guard case .exportParts(.stopped(let stop))? = error else { return nil }
        return stop
    }

    /// The names of the part files in the folder of `fixture`.
    static func partFiles(_ fixture: ExportStudioFixture) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixture.package.folder.url.path).filter {
            $0.hasPrefix("Ep-")
        }.sorted()
    }

    /// U9, C10. Control: a caller loop of `Studio.export` for each part starts part 4 after the take.
    @Test func aTakeInAnotherWindowEndsTheSetBeforeTheNextPart() async throws {
        let a = try await ExportStudioFixture.make()
        let hal = TestHAL([a.mic])
        let studioA = try await a.open(hal)
        let b = try await Self.tenParts()
        let studioB = try await b.open(seam: ChunkSeam(pause: longChunk))
        let targets = Self.targets(studioB, b)
        #expect(targets.count == 10)
        let export = Self.startSet(studioB, b)
        await until(limit: .seconds(30), "part 3 did not start") { studioB.exportFile?.number == 3 }
        studioA.otherStudios = { [studioB] }

        let host = try await StudioExportTests().start(.startTake, studioA, a)

        let stop = try #require(await Self.stop(of: export))
        #expect(stop.error == .cancelled)
        #expect(stop.written.map(\.url) == Array(targets[0..<2]))
        #expect(stop.remaining == Array(targets[2...]))
        #expect(studioB.exportStop == .take)
        #expect(studioB.exportProgress == nil)
        #expect(try Self.partFiles(b) == targets[0..<2].map(\.lastPathComponent))
        #expect(try b.temporaryFiles() == [])
        try await StudioExportTests().recordAndStop(studioA, hal, from: host)
    }

    /// C10: the disk check of a take ends a set to the volume of the take, and the take runs on.
    /// Control: a job URL on another volume lets the set run, and the take stops for low disk.
    @Test func aTakeDiskCheckEndsASetOnItsVolume() async throws {
        let a = try await ExportStudioFixture.make()
        let hal = TestHAL([a.mic])
        let studioA = try await a.open(hal)
        let folderB = LockedBox<URL>()
        studioA.environment.freeBytes = { _ in
            let temporary = folderB.value.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }?
                .contains { $0.hasSuffix(".tmp") }
            return temporary == true ? 0 : 100_000_000_000
        }
        try await studioA.startRecording(armed: ["t1"])
        let b = try await Self.tenParts()
        let studioB = try await b.open(seam: ChunkSeam(pause: longChunk))
        let targets = Self.targets(studioB, b)
        let export = Self.startSet(studioB, b)
        await until(limit: .seconds(30), "B made no temporary file") { (try? b.temporaryFiles())?.isEmpty == false }
        studioA.otherStudios = { [studioB] }
        folderB.value = b.package.folder.url

        await until(limit: .seconds(30), "neither B nor the take ended") {
            studioB.exportProgress == nil || studioA.transport != .recording(take: 1)
        }

        let stop = try #require(await Self.stop(of: export))
        #expect(stop.error == .cancelled)
        #expect(stop.written.map(\.url) + stop.remaining == targets)
        #expect(studioB.exportStop == .take)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(studioA.transport == .recording(take: 1))
        #expect(try Self.partFiles(b) == stop.written.map(\.url.lastPathComponent))
        #expect(try b.temporaryFiles() == [])
        try await studioA.stopRecording()
    }

    /// C10, the cancel of the job handle reaches the GCD loop: Cancel in the sheet.
    @Test func aCancelEndsTheSetAndNamesTheWrittenFiles() async throws {
        let fixture = try await Self.tenParts()
        let studio = try await fixture.open(seam: ChunkSeam(pause: longChunk))
        let targets = Self.targets(studio, fixture)
        let export = Self.startSet(studio, fixture)
        await until(limit: .seconds(30), "part 2 did not start") { studio.exportFile?.number == 2 }

        studio.cancelExport()

        let stop = try #require(await Self.stop(of: export))
        #expect(stop.error == .cancelled)
        #expect(stop.written.map(\.url) == [targets[0]])
        #expect(stop.remaining == Array(targets[1...]))
        #expect(studio.exportStop == .user)
        #expect(try Self.partFiles(fixture) == [targets[0].lastPathComponent])
        #expect(try fixture.temporaryFiles() == [])
    }

    /// C10: the close of the window ends the set.
    @Test func settleEndsTheSet() async throws {
        let fixture = try await Self.tenParts()
        let studio = try await fixture.open(seam: ChunkSeam(pause: longChunk))
        let export = Self.startSet(studio, fixture)
        await until(limit: .seconds(30), "part 2 did not start") { studio.exportFile?.number == 2 }

        await studio.settle()

        let stop = try #require(await Self.stop(of: export))
        #expect(stop.error == .cancelled)
        #expect(stop.written.count == 1)
        #expect(stop.remaining.count == 9)
        #expect(studio.exportStop == .close)
        #expect(studio.exportProgress == nil)
        #expect(try fixture.temporaryFiles() == [])
    }

    /// C10: a set is one export job.
    @Test func aSecondExportDuringTheSetIsBusy() async throws {
        let fixture = try await Self.tenParts()
        let studio = try await fixture.open(seam: ChunkSeam(pause: longChunk))
        let export = Self.startSet(studio, fixture)
        await until(limit: .seconds(30), "the set did not start") { studio.exportFile != nil }

        await #expect(throws: StudioError.busy) {
            try await studio.export(fixture.source, fixture.options, to: fixture.out, replacing: nil)
        }
        studio.cancelExport()
        _ = await Self.stop(of: export)
        #expect(!FileManager.default.fileExists(atPath: fixture.out.path))
    }

    /// C10, lead ruling 1b row 7: the job session has no chapter, so nothing is written.
    @Test func aDeletedPointBeforeTheJobRefusesTheSet() async throws {
        let fixture = try await ExportStudioFixture.make { package in
            try package.session.setMarker(Marker(id: MarkerID("c"), name: "Talk", position: 240_000, kind: .chapter))
        }
        let studio = try await fixture.open()
        #expect(Self.targets(studio, fixture).count == 2)
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.package.folder.url.path).sorted()
        try studio.edit(ripple: false) { session throws(SessionError) in try session.removeMarker(MarkerID("c")) }

        await #expect(throws: StudioError.exportParts(.noPoint(.chapters, Self.range))) {
            try await Self.startSet(studio, fixture).value
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.package.folder.url.path).sorted() == before)
        #expect(studio.exportProgress == nil)
    }

    /// The 10 s tone with chapters "A" at 0 and "B" at 3 s.
    static func twoParts() async throws -> ExportStudioFixture {
        try await ExportStudioFixture.make { package in
            try package.session.setMarker(Marker(id: MarkerID("a"), name: "A", position: 0, kind: .chapter))
            try package.session.setMarker(Marker(id: MarkerID("b"), name: "B", position: 144_000, kind: .chapter))
        }
    }

    /// C10, H2. Control: the parts of the caller session give part 2 a length of 7 s.
    @Test func aMoveBeforeTheJobGivesThePartsOfTheJobSession() async throws {
        let fixture = try await Self.twoParts()
        let studio = try await fixture.open()
        #expect(Self.targets(studio, fixture).count == 2)
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setMarker(Marker(id: MarkerID("b"), name: "B", position: 192_000, kind: .chapter))
        }

        let result = try await Self.startSet(studio, fixture).value

        #expect(result.files.map(\.part.range) == [0..<192_000, 192_000..<480_000])
        #expect(try ExportTests.read(result.files[1].url).length == 288_000)
    }

    /// C10, H2: a rename after the caller listed the targets meets an item that nobody confirmed.
    @Test func aRenameBeforeTheJobRefusesAnUnconfirmedTarget() async throws {
        let fixture = try await Self.twoParts()
        let studio = try await fixture.open()
        let folder = fixture.package.folder.url
        #expect(Self.targets(studio, fixture).map(\.lastPathComponent) == ["Ep-01-A.wav", "Ep-02-B.wav"])
        let unconfirmed = folder.appending(path: "Ep-02-C.wav")
        try Data("old".utf8).write(to: unconfirmed)
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setMarker(Marker(id: MarkerID("b"), name: "C", position: 144_000, kind: .chapter))
        }

        await #expect(throws: StudioError.exportParts(.exists([unconfirmed]))) {
            try await Self.startSet(studio, fixture).value
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == before)
        #expect(try Data(contentsOf: unconfirmed) == Data("old".utf8))
    }
}
