import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The timeline in a real session window (decision 0017, timeline-view criteria 16 and 19).
@MainActor struct TimelineViewTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    /// Criterion 19: the transport bar warns only for an armed clip at the playhead that is not in
    /// view. Controls: an armed lane in view does not warn; nothing is in view before a layout.
    @Test func theRecordOverWarningNeedsAnArmedClipOutOfView() async throws {
        let window = await app.open(try await timelinePackage(in: folder.url, tracks: 8, seconds: 20))
        let studio = try #require(await window.opened() ? window.studio : nil)
        await studio.perform(.seek(.frame(100_000)))
        let visible = TimelineVisible(frames: 0..<737_280, lanes: 0..<5)

        window.armed = ["t7"]
        window.timeline.visible = nil
        #expect(window.showsRecordOver, "before the first layout")
        window.timeline.visible = visible
        #expect(window.showsRecordOver, "lane 7 is under the visible lanes")

        window.armed = ["t2"]
        #expect(!window.showsRecordOver, "lane 2 is in view")
        window.timeline.visible = TimelineVisible(frames: 200_000..<937_280, lanes: 0..<5)
        #expect(window.showsRecordOver, "the playhead is before the visible frames")
        await window.close()
    }
}
