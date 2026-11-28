import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Item 1820: the header menu leaves a header host that outlives its window. The host keeps its
/// SwiftUI graph, so each header view must keep no strong studio, and so no package lock.
@Suite(.serialized) @MainActor struct HeaderLockTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
    }

    /// A header host that the test keeps, and the studio of the window that it came from.
    struct Kept {
        let package: URL
        let host: HeaderHost
        weak var studio: Studio?
    }

    /// Opens a package of two tracks, keeps the header host, and closes the window. With
    /// `liveAt`, the lanes get that height and track t1 gets a monitor state first, so a
    /// `CompactLiveState` (under 56 pt) or a `LiveState` is in the graph that the host keeps.
    func closeKeepingHost(liveAt laneHeight: Double? = nil) async throws -> Kept {
        let package = try await timelinePackage(in: folder.url, tracks: 2, seconds: 20)
        let (model, studio, window, view) = try await openLanes(app, package)
        if let laneHeight {
            model.timeline.laneHeight = .fixed(laneHeight)
            await until("the lanes take the height") { view.lanes.inputs?.laneHeight == laneHeight }
            model.headerRuns.rows = 0
            studio.liveTracks["t1"] = LiveTrack(state: .monitoring, droppedFrames: 0, peak: 0.1)
            await until("the live state runs a row body") {
                drawNow(window)
                return model.headerRuns.rows > 0
            }
            await runLoopPass()
        }
        let kept = Kept(package: package, host: view.headers.host, studio: studio)
        await model.close()
        return kept
    }

    /// The studio goes with the window although the host stays, and the package opens again.
    func expectNoLock(_ kept: Kept) async {
        await until(limit: .seconds(10), "the closed window drops its studio") { kept.studio == nil }
        guard kept.studio == nil else { return }
        let again = await app.open(kept.package)
        #expect(await again.opened(), "the package opens again")
        await again.close()
        withExtendedLifetime(kept.host) {}
    }

    @Test func aHeaderHostThatOutlivesItsWindowKeepsNoLock() async throws {
        await expectNoLock(try await closeKeepingHost())
    }

    /// 50 pt is a one-line row (`CompactLiveState`), 100 pt a two-line row (`LiveState`).
    @Test(arguments: [50.0, 100.0])
    func aHeaderHostWithALiveStateThatOutlivesItsWindowKeepsNoLock(laneHeight: Double) async throws {
        await expectNoLock(try await closeKeepingHost(liveAt: laneHeight))
    }
}
