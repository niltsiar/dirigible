import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// The context menu of the lanes (decision 0037, `ui-panel.md` 4): three groups of the Edit and
/// Markers commands, with no Undo item and no keys. An item that does not apply hides, but Cut, Copy,
/// Paste, and Paste to Fill Selection dim. During a take only the marker group shows; it dims by the
/// Markers menu rule. A pending or split take hides the ripple items (Cut, Insert, Replace, and Delete
/// and Close Gap). A clip set has no Delete and Close Gap, Replace, or Paste to Fill Selection; its Cut
/// is no ripple, so it shows also under a pending or split take (decision 0038).
enum LaneMenu {
    struct Item: Equatable {
        let command: TimelineCommand
        let enabled: Bool
    }

    /// The groups of the menu, with no empty group. `split` is true when a clip is at the split
    /// frames; `clips` is true for a clip set with a clip; `stereo` is true when the selection holds a
    /// stereo clip; `denoise` is true when it holds a clip that Reduce Noise and Repair Sound take; `restore` is true
    /// when it holds a clip on a rendered file; `closeGaps` is true for a clip set of 2 or more clips (Close Gaps is no
    /// ripple, so a pending or split take does not hide it).
    static func groups(
        selection: Bool, clips: Bool, stereo: Bool, denoise: Bool, restore: Bool, clipboard: Bool, split: Bool,
        canEdit: Bool, canRipple: Bool, closeGaps: Bool
    ) -> [[Item]] {
        let ripple = canEdit && canRipple
        let range = selection && !clips
        let edits: [[Item?]] = [
            [
                ripple || clips ? Item(command: .cut, enabled: selection) : nil,
                Item(command: .copy, enabled: selection), Item(command: .paste, enabled: clipboard),
                range ? Item(command: .fill, enabled: clipboard) : nil,
                ripple && clipboard ? Item(command: .insert, enabled: true) : nil,
                ripple && range && clipboard ? Item(command: .replace, enabled: true) : nil,
            ],
            [
                selection ? Item(command: .delete, enabled: true) : nil,
                ripple && range ? Item(command: .deleteCloseGap, enabled: true) : nil,
                split ? Item(command: .split, enabled: true) : nil,
                stereo ? Item(command: .splitStereo, enabled: true) : nil,
                denoise ? Item(command: .reduceNoise, enabled: true) : nil,
                denoise ? Item(command: .repairSound, enabled: true) : nil,
                denoise ? Item(command: .levelOverTime, enabled: true) : nil,
                restore ? Item(command: .restoreOriginal, enabled: true) : nil,
                selection ? Item(command: .fade, enabled: true) : nil,
                closeGaps ? Item(command: .closeGaps, enabled: true) : nil,
            ],
        ]
        let markers = [Item(command: .addMarker, enabled: true), Item(command: .addChapter, enabled: true)]
        return ((canEdit ? edits.map { $0.compactMap { $0 } } : []) + [markers]).filter { !$0.isEmpty }
    }
}

extension TimelineScrollView {
    /// The lane menu at a lane point. A right-click on a clip outside the selection first selects
    /// that clip, as a click does; inside the selection and in a gap, the selection stays. Nil
    /// during a gesture.
    func laneMenu(at place: Place) -> NSMenu? {
        guard !gesture.isActive, let model, let studio, let source, let context = context(source) else { return nil }
        if let selection = TimelineGesture.contextSelection(at: place, context) { model.timeline.selection = selection }
        let session = studio.session
        let selection = model.timeline.selection
        let points = selection.splitPoints(playhead: studio.playhead, in: session)
        var copy = session
        let split = (try? copy.splitClips(at: points.frames, on: points.tracks))?.isEmpty == false
        let groups = LaneMenu.groups(
            selection: !selection.isEmpty(in: session), clips: selection.marks == nil,
            stereo: !selection.stereoClips(in: session).isEmpty,
            denoise: !model.denoiseClips(in: session).isEmpty,
            restore: !model.restoreClips(in: session).isEmpty,
            clipboard: model.clipboard != nil,
            split: split,
            canEdit: model.canEdit, canRipple: context.canRipple,
            closeGaps: selection.marks == nil && selection.selectedClips(in: session).count >= 2)
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for item in group {
                guard
                    let title = TimelineCommand.menuItems[item.command]?.title
                        ?? TimelineCommand.keylessTitles[item.command]
                else { continue }
                let menuItem = NSMenuItem(title: title.text, action: #selector(laneMenuItem(_:)), keyEquivalent: "")
                (menuItem.target, menuItem.representedObject, menuItem.isEnabled) = (
                    self, item.command, item.enabled && model.isOn(item.command)
                )
                menu.addItem(menuItem)
            }
        }
        return menu
    }

    /// Runs the command of a lane menu item, as its Edit or Markers item does.
    @objc func laneMenuItem(_ item: NSMenuItem) {
        guard let command = item.representedObject as? TimelineCommand else { return }
        model?.run(command)
    }
}
