import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// C18 of decision 0053: the lane menu has Duplicate.
extension LaneMenuTests {
    /// Duplicate is the last item of group 1 with a range or a clip set, and it is enabled. It is no
    /// ripple, so a pending or split take does not hide it, but no selection and a take do. Control:
    /// the same call with `selection` false.
    @Test func duplicateIsLastInTheFirstGroup() {
        func groups(
            selection: Bool = true, clips: Bool = false, ripple: Bool = true, canEdit: Bool = true
        ) -> [[LaneMenu.Item]] {
            LaneMenu.groups(
                selection: selection, clips: clips, stereo: false, denoise: false, restore: false, clipboard: true,
                split: false, canEdit: canEdit, canRipple: ripple, closeGaps: false)
        }
        func first(_ groups: [[LaneMenu.Item]]) -> [TimelineCommand] { groups[0].map(\.command) }
        #expect(first(groups()) == [.cut, .copy, .paste, .fill, .insert, .replace, .duplicate], "a range")
        #expect(first(groups(clips: true)) == [.cut, .copy, .paste, .insert, .duplicate], "a clip set")
        #expect(first(groups(ripple: false)) == [.copy, .paste, .fill, .duplicate], "pending take, range")
        #expect(first(groups(clips: true, ripple: false)) == [.cut, .copy, .paste, .duplicate], "pending take, set")
        #expect(groups()[0].last == LaneMenu.Item(command: .duplicate, enabled: true))
        #expect(first(groups(selection: false)) == [.cut, .copy, .paste, .insert], "no selection")
        #expect(!groups(canEdit: false).joined().map(\.command).contains(.duplicate), "a take")
    }
}
