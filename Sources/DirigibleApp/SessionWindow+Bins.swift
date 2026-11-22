import AppKit
import DirigibleAudio
import DirigibleCore

/// The segments of the leading pane (F22, UI panel Q1). Both share the pane, its width, and its handle.
enum PaneSegment: String {
    case index, bins
}

/// The row of an open rename field of the Bins list.
enum BinRename: Hashable {
    case bin(BinID)
    case item(BinItemID)
}

/// The show, the hide, and the segment of the leading pane (C19), and the keys of the Bins list (C23).
extension SessionWindow {
    /// View > Show Session Index: shows the pane at Index, switches a pane shown at Bins to Index, and
    /// hides the pane only while it shows Index.
    func toggleIndex() { toggle(.index) }

    /// View > Show Bins: shows the pane at Bins, switches a pane shown at Index to Bins, and hides the
    /// pane only while it shows Bins (C21).
    func toggleBins() { toggle(.bins) }

    /// The Sidebar item of the toolbar: shows a hidden pane at its last segment, and hides a shown pane
    /// at either segment.
    func toggleSidebar() {
        if leadingPane.shown { hidePane() } else { showPane(at: leadingPane.segment) }
    }

    /// The switch at the pane top. It changes the segment, not the width. A switch away from Bins saves
    /// the open rename, as a hide does: the list leaves the window, so its field gets no focus loss.
    func selectSegment(_ segment: PaneSegment) {
        let focused = paneHasFocus
        if segment != .bins { finishBinRename(save: true) }
        leadingPane.segment = segment
        app?.defaults?.set(segment.rawValue, forKey: LeadingPaneState.segmentKey)
        if focused { focusLanes() }
    }

    private func toggle(_ segment: PaneSegment) {
        if leadingPane.shown, leadingPane.segment == segment { hidePane() } else { showPane(at: segment) }
    }

    /// A show widens a window that is too narrow. A switch with the focus in the pane gives it to the lanes.
    func showPane(at segment: PaneSegment) {
        if leadingPane.segment != segment { selectSegment(segment) }
        guard !leadingPane.shown else { return }
        _ = cancelIndexDrag()
        leadingPane.shown = true
        app?.defaults?.set(true, forKey: LeadingPaneState.shownKey)
        widenForPanes()
    }

    /// A hide ends an index drag that got no mouse-up, and gives a focus in the pane to the lanes.
    private func hidePane() {
        _ = cancelIndexDrag()
        let focused = paneHasFocus
        if leadingPane.binRename != nil { finishBinRename(save: true) }
        leadingPane.shown = false
        app?.defaults?.set(false, forKey: LeadingPaneState.shownKey)
        if focused { focusLanes() }
    }

    /// Edit > Find in Session Index: the pane shows at Index, and the search field takes the focus.
    func findInIndex() {
        showPane(at: .index)
        leadingPane.searchFocusRequest = true
        focusIndexSearch()
    }

    /// True when the first responder is in the pane: the index list, its search field, or the Bins list.
    var paneHasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        for table in [leadingPane.table, leadingPane.binsTable] as [NSView?] {
            if let table, responder.isDescendant(of: table) { return true }
        }
        guard let field = (responder as? NSTextView)?.delegate as? NSTextField else { return false }
        return field === leadingPane.searchField
    }

    /// True when the first responder of `keyWindow` is the Bins list and no rename field is open: the
    /// field editor is a subview of the list, and its keys are text.
    func binsListHasFocus(in keyWindow: NSWindow?) -> Bool {
        guard leadingPane.shown, leadingPane.segment == .bins, leadingPane.binRename == nil, keyWindow === window,
            let table = leadingPane.binsTable, let responder = keyWindow?.firstResponder as? NSView
        else { return false }
        return responder.isDescendant(of: table)
    }

    /// A timeline command with the focus in the Bins list (`TimelineCommand.binsFocus`). True when the
    /// list took it. Command-Return, Shift-Return, and Return act on the item only for a key press; a
    /// menu click of their items acts as in the lanes.
    func binsCommand(_ command: TimelineCommand, isKey: Bool) -> Bool {
        switch command.binsFocus {
        case .lanes: return false
        case .beep:
            beep()
            return true
        case .item:
            guard isKey || command == .delete else { return false }
            guard let id = leadingPane.selectedBinItem else {
                beep()
                return true
            }
            switch command {
            case .addMarker: pasteBinItem(id, insert: false)
            case .markerInfo: pasteBinItem(id, insert: true)
            case .renameTrack: beginBinRename(.item(id))
            default: removeBinItem(id)
            }
            return true
        }
    }
}

extension AppDelegate {
    /// The title and the state of View > Show/Hide Session Index for the key window. The title reads
    /// "Hide" only while the pane shows Index.
    var indexItem: (title: L10n, enabled: Bool) { indexItem(for: key) }

    func indexItem(for model: SessionWindow?) -> (title: L10n, enabled: Bool) {
        (shows(.index, model) ? .menuViewIndexHide : .menuViewIndexShow, model != nil)
    }

    /// View > Show/Hide Bins: "Hide" only while the pane shows Bins (C21).
    var binsItem: (title: L10n, enabled: Bool) { binsItem(for: key) }

    func binsItem(for model: SessionWindow?) -> (title: L10n, enabled: Bool) {
        (shows(.bins, model) ? .menuViewBinsHide : .menuViewBinsShow, model != nil)
    }

    private func shows(_ segment: PaneSegment, _ model: SessionWindow?) -> Bool {
        model?.leadingPane.shown == true && model?.leadingPane.segment == segment
    }

    /// The action of Edit > Find in Session Index and its key.
    func findInIndex() { key?.findInIndex() }
}
