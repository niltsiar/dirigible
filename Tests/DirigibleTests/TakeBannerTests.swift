import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 2026-10-16-observation-hang C6 and C7: the periodic content of the take banner reads no
/// model. On macOS 14 a registration that each tick makes again can stay until the next change
/// of its key path, and that change then cancels all of them on the main thread.
@Suite(.serialized) @MainActor struct TakeBannerTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
    }

    /// C6: each periodic update of a user take makes no registration on the agent take or the take
    /// start. The registrations are counted after each update, as the live ones of the rows are.
    @Test func aPeriodicUpdateReadsNoModel() async throws {
        let (model, studio, window, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 1, seconds: 5))
        model.bannerTick = 0.05
        studio.recordingSince = .now
        studio.transport = .recording(take: 1)
        await until(limit: .seconds(3), "the banner runs its first update") { model.bannerRuns > 0 }
        var made: [String: Int] = [:]
        for _ in 1...3 {
            let runs = model.bannerRuns
            let modelBefore = try #require(registrations(of: model))
            let studioBefore = try #require(registrations(of: studio))
            await until(limit: .seconds(3), "the banner runs another update") {
                window.contentView?.layoutSubtreeIfNeeded()
                return model.bannerRuns > runs
            }
            let modelAfter = try #require(registrations(of: model))
            let studioAfter = try #require(registrations(of: studio))
            for (path, count) in modelAfter.made(since: modelBefore.next) where path == \SessionWindow.agentRecord {
                made["\(path)", default: 0] += count
            }
            for (path, count) in studioAfter.made(since: studioBefore.next) where path == \Studio.recordingSince {
                made["\(path)", default: 0] += count
            }
        }
        let quiet = made.isEmpty
        #expect(quiet, "C6: new registrations over 3 periodic updates: \(made.sorted { $0.key < $1.key })")
        studio.transport = .idle
        window.close()
        await model.close()
    }

    /// C7: the elapsed time of a user take counts whole seconds from the take start.
    @Test func theElapsedTimeCountsFromTheTakeStart() {
        let now = ContinuousClock.now
        #expect(TakeBanner.elapsed(since: now - .seconds(65) - .milliseconds(900), now: now) == "0:01:05")
        #expect(TakeBanner.elapsed(since: nil, now: now) == "")
    }
}
