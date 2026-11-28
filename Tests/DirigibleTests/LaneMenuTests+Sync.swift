import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// C18 of decision 0076: the lane menu of one clip with a reference track has Sync Clip to Track.
extension LaneMenuTests {
    /// The item is in the tools group after Restore Original Audio, only for `sync`. Control: a menu
    /// with no `sync` argument has no item.
    @Test func theSyncItemShowsForOneClipWithAReference() async throws {
        func commands(_ sync: Bool) -> [[TimelineCommand]] {
            LaneMenu.groups(
                selection: true, clips: true, stereo: false, denoise: true, restore: true, clipboard: false,
                split: false, canEdit: true, canRipple: true, closeGaps: false, sync: sync
            ).map { $0.map(\.command) }
        }
        let tools: [TimelineCommand] = [.delete, .reduceNoise, .repairSound, .levelOverTime, .restoreOriginal]
        let edits: [TimelineCommand] = [.cut, .copy, .paste, .duplicate]
        #expect(commands(true) == [edits, tools + [.syncClip, .fade], [.addMarker, .addChapter]])
        #expect(commands(false) == [edits, tools + [.fade], [.addMarker, .addChapter]])

        let (model, studio, window, view) = try await lanes()
        let title = L10n.menuToolsSyncClip.text
        #expect(titles(try menu(view, 120, 10)).contains(title), "one clip with a reference on t2")

        let held = studio.session.tracks[0].clips.map(\.id)
        model.timeline.selection = .clips(try #require(ClipSet(Set(held[0...1]))))
        #expect(!titles(try menu(view, 20, 10)).contains(title), "a clip set of two clips")

        model.timeline.marks = Marks(inPoint: 40_000, outPoint: 100_000, tracks: ["t1"])
        #expect(!titles(try menu(view, 120, 10)).contains(title), "a range selection")
        window.close()
        await model.close()
    }

    /// The item runs the command of the menu, so a click opens the sheet for that clip.
    @Test func theSyncItemOpensTheSheet() async throws {
        let (model, _, window, view) = try await lanes()
        let menu = try menu(view, 120, 10)
        let item = try #require(menu.items.first { $0.title == L10n.menuToolsSyncClip.text })
        #expect(item.isEnabled)
        _ = (item.target as AnyObject).perform(item.action, with: item)
        #expect(model.syncDraft?.reference == "t2", "\(String(describing: model.syncDraft))")
        window.close()
        await model.close()
    }
}
