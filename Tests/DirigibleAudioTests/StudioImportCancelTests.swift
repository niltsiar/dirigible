import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The late cancel and the studio fraction of `Studio.importAudio` (decision 0049, C4 and C16).
@MainActor
struct StudioImportCancelTests {
    let target = ImportTarget(track: "t1", start: 96_000)

    /// Runs one import of the fixture source, and gives its error, or nil.
    func run(_ studio: Studio, _ fixture: ImportStudioFixture, to target: ImportTarget? = nil)
        -> Task<StudioError?, Never>
    {
        let (source, target) = (fixture.source, target ?? self.target)
        return Task {
            do throws(StudioError) {
                _ = try await studio.importAudio(source, to: target) { _ in }
                return nil
            } catch {
                return error
            }
        }
    }

    /// G23: a cancel after the work returns, before the save, removes the renamed WAV: the run
    /// owns the last cancel read.
    @Test func aCancelAfterTheWorkRemovesTheWAV() async throws {
        let fixture = try await ImportStudioFixture.make()
        let studio = try await fixture.open()
        let gate = AsyncGate()
        studio.environment.importWorkDone = { await gate.wait() }
        let (xml, names) = (fixture.xml, fixture.clipsNames)

        let import1 = run(studio, fixture)
        await gate.entered()
        #expect(fixture.clipsNames == (names + ["Voice.wav"]).sorted(), "the work made the WAV")
        studio.cancelImport()
        gate.open()

        #expect(await import1.value == .audioImport(.cancelled))
        #expect(fixture.clipsNames == names, "the cancel left the WAV: \(fixture.clipsNames)")
        #expect(fixture.xml == xml && !studio.canUndo, "a cancelled import saved")
    }

    /// Agent-pack C8: a late cancel of an import with the ID "X" removes the WAV of the stem, and a
    /// file at `Clips/X.wav` keeps its bytes.
    @Test func aCancelledImportWithAnIDRemovesTheStemWAV() async throws {
        let fixture = try await ImportStudioFixture.make()
        let other = fixture.url.appending(path: "\(clipsFolderName)/X.wav")
        let bytes = Data("not the import".utf8)
        try bytes.write(to: other)
        let studio = try await fixture.open()
        let gate = AsyncGate()
        studio.environment.importWorkDone = { await gate.wait() }
        let (xml, names) = (fixture.xml, fixture.clipsNames)

        let import1 = run(studio, fixture, to: ImportTarget(track: "t1", start: 96_000, clip: "X"))
        await gate.entered()
        #expect(fixture.clipsNames == (names + ["Voice.wav"]).sorted(), "the work made the WAV of the stem")
        studio.cancelImport()
        gate.open()

        #expect(await import1.value == .audioImport(.cancelled))
        #expect(fixture.clipsNames == names, "the cancel left the WAV: \(fixture.clipsNames)")
        #expect(FileManager.default.contents(atPath: other.path) == bytes, "the cancel changed Clips/X.wav")
        #expect(fixture.xml == xml && !studio.canUndo, "a cancelled import saved")
    }

    /// Agent-pack C12: a late cancel of an import that reused `Voice.wav` keeps that WAV and
    /// `session.xml`: the reuse made no file, so the cancel removes none.
    @Test func aCancelledImportThatReusedAFileKeepsTheFile() async throws {
        let fixture = try await ImportStudioFixture.make()
        let studio = try await fixture.open()
        #expect(await run(studio, fixture).value == nil, "the first import")
        let wav = fixture.url.appending(path: "\(clipsFolderName)/Voice.wav")
        let bytes = try #require(FileManager.default.contents(atPath: wav.path))
        let gate = AsyncGate()
        studio.environment.importWorkDone = { await gate.wait() }
        let (xml, names) = (fixture.xml, fixture.clipsNames)

        let import2 = run(studio, fixture, to: ImportTarget(track: "t1", start: 500_000))
        await gate.entered()
        #expect(fixture.clipsNames == names, "the work reused Voice.wav: \(fixture.clipsNames)")
        studio.cancelImport()
        gate.open()

        #expect(await import2.value == .audioImport(.cancelled))
        let kept = FileManager.default.contents(atPath: wav.path) == bytes
        #expect(kept && fixture.clipsNames == names, "the cancel changed Clips/: \(fixture.clipsNames)")
        #expect(fixture.xml == xml, "a cancelled import saved")
    }

    /// G24: the studio fraction keeps the largest value of the run, and the next run starts at 0.
    @Test func theImportFractionStartsAtZeroForEachRun() async throws {
        let fixture = try await ImportStudioFixture.make()
        let studio = try await fixture.open()
        #expect(await run(studio, fixture).value == nil)
        await until(limit: .seconds(10), "the first run shows no progress") { studio.importProgress > 0 }

        let gate = Gate(limit: nil)
        defer { gate.open() }
        studio.environment.importStep = { gate.waitOnce() }
        let import2 = run(studio, fixture)
        await gate.entered()
        #expect(studio.importProgress == 0, "the second run starts at \(studio.importProgress)")
        gate.open()
        #expect(await import2.value == nil)
    }
}
