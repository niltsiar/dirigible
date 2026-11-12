import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import SwiftUI

/// The state of the leading pane of a session window (decision 0023): whether it shows, its
/// segment and width, the kind filter and the search of the index, the index table, and the cache
/// of the index rows. Only the shown pane builds rows.
@Observable @MainActor final class LeadingPaneState {
    /// The segments of the switch. The Bins segment of the favorites run joins this list.
    enum Segment: CaseIterable { case index }

    /// The app preference of View > Show Session Index: a `Bool`, default false.
    static let shownKey = "view.index.shown"

    var shown: Bool
    var width: IndexWidth
    var segment = Segment.index
    /// The kind filter; nil shows all kinds.
    var kind: SessionIndex.Kind?
    var search = ""
    /// The table of the index list, from its view.
    @ObservationIgnored weak var table: IndexTableView?
    /// The selected rows that the window last pushed, for a table that reloads. The window pushes
    /// them from the `didSet` of `SessionWindow.timeline`, so no SwiftUI body reads them.
    @ObservationIgnored private(set) var pushedRows: Set<SessionIndex.Pick> = []
    @ObservationIgnored private(set) var pushedAnchor: SessionIndex.Pick?
    @ObservationIgnored private(set) var pushes = 0
    /// The runs of `followRows`, for the tests.
    @ObservationIgnored var reconciles = 0
    /// VoiceOver says a text. Tests give their own.
    @ObservationIgnored var announce: (String) -> Void = { postAnnouncement($0, priority: .high) }
    @ObservationIgnored var drag = PaneDrag<IndexWidth>()
    /// The target of a drag and the fitted width that the pointer asks for, as the inspector's.
    @ObservationIgnored var preview: IndexWidth?
    @ObservationIgnored var request: IndexWidth?
    @ObservationIgnored let guide = CALayer()
    @ObservationIgnored private var indexCache: (session: Session, index: SessionIndex)?
    /// The row builds of this window, for the tests.
    @ObservationIgnored private(set) var builds = 0

    init(defaults: UserDefaults?) {
        shown = defaults?.bool(forKey: Self.shownKey) ?? false
        width = IndexWidth(stored: defaults?.object(forKey: IndexWidth.defaultsKey))
    }

    func pushRows(_ rows: Set<SessionIndex.Pick>, anchor: SessionIndex.Pick?) {
        (pushedRows, pushedAnchor) = (rows, anchor)
        pushes += 1
        (table?.dataSource as? IndexTableSource)?.showSelection()
    }

    /// The rows of `session`. A new Session value builds them again; the same value gives the
    /// cached rows.
    func sessionIndex(for session: Session) -> SessionIndex {
        if let cache = indexCache, cache.session == session { return cache.index }
        let index = SessionIndex(session: session)
        indexCache = (session, index)
        builds += 1
        return index
    }
}

extension SessionWindow {
    /// The `didSet` of `timeline`: a change of the selected rows goes to the list.
    func rowsChanged(since old: TimelineState) {
        guard timeline.rowsRevision != old.rowsRevision else { return }
        leadingPane.pushRows(timeline.selectedRows, anchor: timeline.anchorRow)
    }

    /// The row action of the list. A click or an arrow selects the row's item in the lanes and in
    /// the list, and, while the studio is idle, seeks to the row and shows it. A click during play
    /// seeks and the play goes on; an arrow during play does not jump. During a take or an import
    /// the playhead and the view stay.
    func selectIndexRow(_ row: SessionIndex.Row, byClick: Bool) {
        guard let studio else { return }
        timeline.selectRows([row.id], anchor: row.id)
        guard studio.isIdle else { return }
        if case .playing = studio.playback, !byClick { return }
        transport(.seek(.frame(row.position)))
        if case .clip(let id, _) = row.item,
            let lane = studio.session.tracks.firstIndex(where: { $0.clips.contains { $0.id == id } })
        {
            timelineView?.reveal(frame: row.position, lane: lane)
        } else {
            timelineView?.navigate(.center(row.position))
        }
    }

    /// The Show Info action and Return on a clip row: the Clip tab; on a marker row, the Marker tab.
    func showIndexInfo(_ row: SessionIndex.Row) {
        selectIndexRow(row, byClick: true)
        if case .clip = row.item {
            if !showsInspector { toggleInspector() }
            selectInspectorTab(.clip)
        } else {
            showMarkerInfo()
        }
    }

    /// Follows the session for the selected rows: an edit from any source drops each selected row
    /// whose item is gone. It writes neither the selection, the current marker, nor the Marks.
    func followRows(_ studio: Studio) {
        withObservationTracking {
            _ = studio.sessionRevision
        } onChange: { [weak self, weak studio] in
            Task { @MainActor in
                guard let self, let studio, self.studio === studio else { return }
                self.dropGoneRows(in: studio.session)
                self.followRows(studio)
            }
        }
    }

    private func dropGoneRows(in session: Session) {
        leadingPane.reconciles += 1
        guard !timeline.selectedRows.isEmpty else { return }
        var live = Set(session.markers.keys.map { SessionIndex.Pick.marker($0) })
        for track in session.tracks { live.formUnion(track.clips.map { .clip($0.id) }) }
        let anchor = timeline.anchorRow
        timeline.pruneRows(keeping: live, order: SessionIndex(session: session).rows.map(\.id))
        if let anchor, !live.contains(anchor) { leadingPane.announce(L10n.indexPostSelectedGone.text) }
    }

    /// True when the first responder of `keyWindow` is the index list. No row field exists yet.
    func indexListHasFocus(in keyWindow: NSWindow?) -> Bool {
        guard leadingPane.shown, keyWindow === window, let table = leadingPane.table,
            let responder = keyWindow?.firstResponder as? NSView
        else { return false }
        return responder.isDescendant(of: table)
    }

    /// A timeline command with the focus in the list (`TimelineCommand.indexFocus`). True when the
    /// list took it. Return and Shift-Return take the list meaning only for a key press.
    func indexCommand(_ command: TimelineCommand, isKey: Bool) -> Bool {
        switch command.indexFocus {
        case .lanes: return false
        case .beep:
            beep()
            return true
        case .rows:
            let only = timeline.selectedRows.count == 1 ? timeline.selectedRows.first : nil
            switch command {
            case .renameTrack where isKey:
                if case .clip? = only, let row = indexRow(only) { showIndexInfo(row) } else { beep() }
            case .markerInfo where isKey:
                if case .marker? = only, let row = indexRow(only) { showIndexInfo(row) } else { beep() }
            case .deleteMarker, .moveMarker:
                if case .marker(let id)? = only, timeline.marker == id { run(command) } else { beep() }
            case .deselectAll: timeline.pruneRows(keeping: [])
            default: return false
            }
            return true
        }
    }

    private func indexRow(_ pick: SessionIndex.Pick?) -> SessionIndex.Row? {
        guard let pick, let session = studio?.session else { return nil }
        return leadingPane.sessionIndex(for: session).rows.first { $0.id == pick }
    }

    /// The least content width of the window: the lanes minimum plus each shown pane (0023).
    var paneMinimum: Double { SessionView.minWidth + shownIndexWidth + (showsInspector ? shownInspectorWidth : 0) }

    /// The width that the index pane takes: 0 while it is hidden.
    var shownIndexWidth: Double { leadingPane.shown ? leadingPane.width.points : 0 }

    /// View > Show Session Index and the toolbar item. The pane shows at the Index segment, and
    /// hides only while it shows Index. A toggle ends an index drag that got no mouse-up. A hide
    /// gives a focus in the pane to the lanes. A show widens a window that is too narrow.
    func toggleIndex() {
        _ = cancelIndexDrag()
        let pane = leadingPane
        if pane.shown && pane.segment == .index {
            let focused = paneHasFocus
            pane.shown = false
            app?.defaults?.set(false, forKey: LeadingPaneState.shownKey)
            if focused { focusLanes() }
            return
        }
        pane.segment = .index
        pane.shown = true
        app?.defaults?.set(true, forKey: LeadingPaneState.shownKey)
        widenForPanes()
    }

    /// True when the first responder is the index list or the search field.
    private var paneHasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        if let table = leadingPane.table, responder.isDescendant(of: table) { return true }
        return ((responder as? NSTextView)?.delegate as? NSTextField)?.accessibilityIdentifier()
            == SessionIndexView.searchIdentifier
    }
}

extension AppDelegate {
    /// The title and the state of View > Show/Hide Session Index for the key window. The title
    /// reads "Hide" only while the pane shows Index.
    var indexItem: (title: L10n, enabled: Bool) { indexItem(for: key) }

    func indexItem(for model: SessionWindow?) -> (title: L10n, enabled: Bool) {
        let hides = model?.leadingPane.shown == true && model?.leadingPane.segment == .index
        return (hides ? .menuViewIndexHide : .menuViewIndexShow, model != nil)
    }
}
