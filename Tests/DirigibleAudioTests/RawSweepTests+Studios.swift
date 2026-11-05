import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The raw sweep job across two studios (decision 0071, C17): a take start in one studio and the
/// job of another studio.
extension RawSweepTests {
    /// A take start in `first` while the job of `second` waits for its turn behind a long turn of
    /// `second` (an import or a level job). The start does not wait for that turn, and the job
    /// removes no CAF in its turn during the take.
    @Test func aTakeStartDoesNotWaitForATurnOfAnotherStudio() async throws {
        let (packageA, packageB) = (try await Self.oldTake().0, try await Self.oldTake().0)
        let (first, hal) = try await Self.armed(packageA)
        await first.rawSweep
        let (second, hold, _) = try await Self.held(packageB, at: .turn)
        defer { hold.gate.open() }
        first.otherStudios = { [weak second] in second.map { [$0] } ?? [] }
        second.otherStudios = { [weak first] in first.map { [$0] } ?? [] }
        let blocker = AsyncGate()
        defer { blocker.open() }
        let long = Task { await second.serialized { await blocker.wait() } }
        await blocker.entered()
        hold.gate.open()
        await until(limit: .seconds(10), "the job does not wait for its turn") { second.writesWaiting == 1 }

        let done = StepCounter()
        let start = Task {
            try await Self.start(first, recorded: false)
            _ = done.next()
        }
        await until(limit: .seconds(10), "the take start waits for the turn of the other studio") { done.calls == 1 }
        let returned = done.calls == 1
        blocker.open()
        guard returned else { return }
        try await start.value
        await long.value
        await second.rawSweep

        #expect(Self.hasCAF(packageB), "the job of the other studio removes no CAF during the take")
        try await Self.stop(first, hal)
        await first.settle()
        await second.settle()
    }

    /// A pending take of another studio records nothing, so it does not hold the job of this
    /// studio: the job removes the CAF of the old take.
    @Test func aPendingTakeOfAnotherStudioDoesNotHoldTheJob() async throws {
        let pending = try TakePackage()
        try pending.segment(arm: 1, samples: sine(seconds: 2, rate: 48_000))
        let clips = pending.url.appending(path: "Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        chmod(clips.path, 0o500)
        let second = try await Studio.open(pending.url)
        chmod(clips.path, 0o755)
        try #require(second.pendingTake?.take == 1, "the finalize fails, so the take stays pending")
        let (package, _) = try await Self.oldTake()
        let (first, hold, _) = try await Self.held(package, at: .first)
        defer { hold.gate.open() }
        first.otherStudios = { [weak second] in second.map { [$0] } ?? [] }

        hold.gate.open()
        await first.rawSweep

        #expect(!Self.hasCAF(package), "the job removes the CAF during a pending take of another studio")
        await first.settle()
        await second.settle()
    }
}
