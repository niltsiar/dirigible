import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The follow mark, the Follow in Ripples item, and the header action (decision 0073, criterion
/// C38). The test process builds no SwiftUI accessibility tree for a hosted view, so the label, the
/// value, the missing button trait, the menu items, and the presence of the header action are
/// checked in the accessibility dump of the app (the on-screen step of L3-S4).
extension HeaderRowTests {
    /// The pixels of each row of `model` at 50 pt lanes, 340 pt wide, right of the role strip.
    func rowPixels(_ model: SessionWindow, _ studio: Studio) async throws -> [[UInt32]] {
        let (lane, width) = (50.0, 340.0)
        let (window, host) = rows(model, studio, laneHeight: lane, width: width)
        defer { window.close() }
        window.orderFront(nil)
        await until(limit: .seconds(10), "each row shows its name field") {
            host.layoutSubtreeIfNeeded()
            return controls(host, in: host).filter { $0.kind == "name" }.count == studio.session.tracks.count
        }
        drawNow(window)
        let capture = try await TimelineColorTests.capture(window)
        return try studio.session.tracks.indices.map { row in
            let rect = NSRect(x: 8, y: Double(row) * lane + 2, width: width - 8, height: lane - 4)
            return try TimelineRulerTests.pixels(of: host.convert(rect, to: nil), capture, window)
        }
    }

    /// C38: a follow track adds the mark to its row. The rows of the other tracks stay as they were.
    @Test func aFollowTrackShowsTheMark() async throws {
        let (model, studio) = try await model(tracks: 3)
        let plain = try await rowPixels(model, studio)

        model.setFollowTrack(true, tracks: ["t2"])
        let marked = try await rowPixels(model, studio)

        func changed(_ row: Int) -> Int { zip(plain[row], marked[row]).filter { $0 != $1 }.count }
        #expect(changed(1) > 30, "the mark and the shifted name: \(changed(1)) pixels")
        #expect(changed(0) == 0 && changed(2) == 0, "rows 0 and 2 stay: \(changed(0)), \(changed(2))")
        await model.close()
    }

    /// C38: the header action calls `setFollowTrack(false, ...)` for its track. It clears that track
    /// only, as one undo entry.
    @Test func theHeaderActionTurnsOffOneTrack() async throws {
        let (model, studio) = try await model(tracks: 2)
        model.setFollowTrack(true, tracks: ["t1", "t2"])
        let before = studio.session

        model.setFollowTrack(false, tracks: ["t1"])

        #expect(studio.session.tracks.map(\.isFollowTrack) == [false, true])
        model.undo()
        #expect(studio.session == before, "one undo")
        await model.close()
    }

    /// C38: Track > Follow in Ripples is checked when each header track follows, and a click sets or
    /// clears the flag of all of them in one entry. The near input is a mix: not checked.
    @Test func theFollowItemIsACheckmarkOnTheSelectedTracks() async throws {
        let (model, studio) = try await model(tracks: 3)
        model.timeline.selection = .range(Marks(tracks: ["t1", "t2"]))
        #expect(model.roleMenuTracks == ["t1", "t2"] && !model.follows(model.roleMenuTracks))
        model.setFollowTrack(true, tracks: ["t1"])
        #expect(!model.follows(model.roleMenuTracks), "a mix is not checked")
        model.setFollowTrack(true, tracks: model.roleMenuTracks)
        #expect(
            model.follows(model.roleMenuTracks) && studio.session.tracks.map(\.isFollowTrack) == [true, true, false])
        model.setFollowTrack(false, tracks: model.roleMenuTracks)
        #expect(studio.session.tracks.allSatisfy { !$0.isFollowTrack })
        model.timeline.selection = .none
        #expect(!model.follows(model.roleMenuTracks), "no track: not checked")
        await model.close()
    }
}
