import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The late cancel and the studio fraction of `Studio.importAudio` (decision 0049, C4 and C16).
@MainActor
struct StudioImportCancelTests {
    let target = ImportTarget(track: "t1", start: 96_000)

    /// Runs one import of the fixture source, and gives its error, or nil.
    func run(_ studio: Studio, _ fixture: ImportStudioFixture) -> Task<StudioError?, Never> {
        let (source, target) = (fixture.source, target)
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
        #expect(fixture.clipsNames == names, "the WAV stays: \(fixture.clipsNames)")
        #expect(fixture.xml == xml && !studio.canUndo, "a cancelled import saved")
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
