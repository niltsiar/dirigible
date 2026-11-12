import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import SwiftUI

/// The state of the leading pane of a session window (decision 0023): whether it shows, its
/// segment and width, the kind filter and the search of the index, the index table, and the cache
/// of the index rows. Only the shown pane builds rows.
@Observable @MainActor final class LeadingPaneState {
    /// The segments of the switch. The switch shows from two segments.
    enum Segment: CaseIterable { case index }

    /// The app preference of View > Show Session Index: a `Bool`, default false.
    static let shownKey = "view.index.shown"

    var shown: Bool
    var width: IndexWidth
    var segment = Segment.index
    /// The kind filter; nil shows all kinds.
    var kind: SessionIndex.Kind?
    var search = ""
    /// True from Find in Session Index until the search field has the focus.
    @ObservationIgnored var searchFocusRequest = false
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
    /// The body runs of the pane, for the tests.
    @ObservationIgnored private(set) var bodies = 0

    /// The open name field of a row: the marker and the text typed so far. The field shows it.
    struct RowEdit: Equatable {
        let marker: MarkerID
        var text: String
    }

    @ObservationIgnored var rowEdit: RowEdit?
    /// The row of the open field. The list keeps it under a filter until the field ends.
    var editedRow: SessionIndex.Pick?

    func countBody() { bodies += 1 }

    func openRowField(select: Bool) { (table?.dataSource as? IndexTableSource)?.openField(select: select) }

    func closeRowField() { (table?.dataSource as? IndexTableSource)?.closeField() }

    init(defaults: UserDefaults?) {
        shown = defaults?.bool(forKey: Self.shownKey) ?? false
        width = IndexWidth(stored: defaults?.object(forKey: IndexWidth.defaultsKey))
    }

    func pushRows(_ rows: Set<SessionIndex.Pick>, anchor: SessionIndex.Pick?) {
        (pushedRows, pushedAnchor) = (rows, anchor)
        pushes += 1
        (table?.dataSource as? IndexTableSource)?.showSelection()
    }

    /// The rows of `session`. A new Session value updates the cached rows; the same value gives them.
    func sessionIndex(for session: Session) -> SessionIndex {
        if let cache = indexCache, cache.session == session { return cache.index }
        let index =
            indexCache.map { SessionIndex(session: session, updating: $0.index, of: $0.session) }
            ?? SessionIndex(session: session)
        indexCache = (session, index)
        builds += 1
        return index
    }
}

extension SessionWindow {
    /// One display tick of the lanes: the play mark of the list takes the head. `started` is a play
    /// start or a take start, which ends the hold of the index follow.
    func indexTick(head: Frames, playback: Playback, taking: Bool, started: Bool) {
        guard let table = leadingPane.table else { return }
        table.mark.tick(
            head: head, running: taking || playback != .stopped, taking: taking, started: started,
            follows: timeline.follows, in: table)
    }

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

    /// A double click, the action Play from here, and the row menu item: the row action, then a play
    /// start while the studio is idle and stopped. During play the click seek keeps the play going.
    /// During a take or an import nothing starts.
    func playFromIndexRow(_ row: SessionIndex.Row, selecting: Bool = true) {
        if selecting { selectIndexRow(row, byClick: true) }
        guard let studio, studio.isIdle, studio.playback == .stopped else { return }
        transport(.playStop)
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
        if let open = leadingPane.rowEdit, session.markers[open.marker] == nil { finishRowEdit(save: false) }
        guard !timeline.selectedRows.isEmpty else { return }
        var live = Set(session.markers.keys.map { SessionIndex.Pick.marker($0) })
        for track in session.tracks { live.formUnion(track.clips.map { .clip($0.id) }) }
        let anchor = timeline.anchorRow
        timeline.pruneRows(keeping: live, order: SessionIndex(session: session).rows.map(\.id))
        if let anchor, !live.contains(anchor) { leadingPane.announce(L10n.indexPostSelectedGone.text) }
    }

    /// True when the first responder of `keyWindow` is the index list and no row field is open: a
    /// field editor is a subview of the list, and its keys are text.
    func indexListHasFocus(in keyWindow: NSWindow?) -> Bool {
        guard leadingPane.shown, leadingPane.rowEdit == nil, keyWindow === window, let table = leadingPane.table,
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
                if case .clip? = only, let row = indexRow(only) {
                    showIndexInfo(row)
                } else if case .marker? = only {
                    renameSelectedIndexRow()
                } else {
                    beep()
                }
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

    /// Return and F2 in the list: the name field of the one selected marker or chapter row. A take
    /// or an import does nothing, as Marker Info; a clip row or two rows beep.
    func renameSelectedIndexRow() {
        guard canEdit else { return }
        guard timeline.selectedRows.count == 1, case .marker(let id)? = timeline.selectedRows.first,
            studio?.session.markers[id] != nil
        else { return beep() }
        beginRowEdit(id)
    }

    /// The row menu and the VoiceOver action Rename: the row is selected, with no seek, and its field opens.
    func renameIndexRow(_ pick: SessionIndex.Pick) {
        guard canEdit, case .marker(let id) = pick else { return }
        timeline.selectRows([pick], anchor: pick)
        beginRowEdit(id)
    }

    /// Opens the name field of `id`. An open field of another row commits first.
    func beginRowEdit(_ id: MarkerID) {
        guard canEdit, let marker = studio?.session.markers[id] else { return }
        finishRowEdit(save: true)
        leadingPane.rowEdit = .init(marker: id, text: marker.name)
        leadingPane.editedRow = .marker(id)
        leadingPane.openRowField(select: true)
    }

    /// Ends the open name field. The state is read and cleared first, so a second caller (the focus
    /// loss after Command-R, or `commitDrafts()` after the focus loss) finds nothing and adds no edit.
    /// With `save`, the typed name goes in one edit. A name that `Marker.set(.name, text:)` refuses
    /// ends the field with the old name; with `strict` (Return and Tab) it beeps and keeps the field,
    /// and the result is false.
    @discardableResult func finishRowEdit(save: Bool, strict: Bool = false) -> Bool {
        guard let open = leadingPane.rowEdit else { return true }
        let stored = idleStudio?.session.markers[open.marker]
        if save, strict, var probe = stored, !probe.set(.name, text: open.text) {
            beep()
            return false
        }
        leadingPane.rowEdit = nil
        leadingPane.editedRow = nil
        leadingPane.closeRowField()
        guard save, var named = stored, named.set(.name, text: open.text), named != stored else { return true }
        let renamed = named
        edit(ripple: false) { s throws(SessionError) in try s.setMarker(renamed) }
        return true
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

    /// Edit > Find in Session Index: the pane shows (it stays shown when it is), and the search field takes the focus.
    func findInIndex() {
        if !(leadingPane.shown && leadingPane.segment == .index) { toggleIndex() }
        leadingPane.searchFocusRequest = true
        focusIndexSearch()
    }

    /// Gives the focus to the search field when the field exists, and ends the request. A pane that
    /// shows just now builds its field later: its list calls this again when it joins the window.
    func focusIndexSearch() {
        guard let field = indexSearchField else { return }
        leadingPane.searchFocusRequest = false
        window?.makeFirstResponder(field)
    }

    /// The search field of the pane. SwiftUI sets no identifier on its `NSTextField`, so it is the
    /// first editable text field outside the list, found from the nearest ancestor of the list that has one.
    var indexSearchField: NSTextField? {
        guard let table = leadingPane.table else { return nil }
        func field(in view: NSView) -> NSTextField? {
            if view === table { return nil }
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap(field).first
        }
        var ancestor = table.superview
        while let view = ancestor {
            if let found = field(in: view) { return found }
            ancestor = view.superview
        }
        return nil
    }

    /// Esc in the search field: text clears first; with no text the lanes take the focus.
    func escapeInIndexSearch() {
        if leadingPane.search.isEmpty { focusLanes() } else { leadingPane.search = "" }
    }

    /// Down Arrow in the search field: the list takes the focus and selects its first row, as an arrow does.
    /// With no row shown it beeps.
    func focusFirstIndexRow() {
        guard let table = leadingPane.table, let first = (table.dataSource as? IndexTableSource)?.rows.first else {
            return beep()
        }
        window?.makeFirstResponder(table)
        selectIndexRow(first, byClick: false)
    }

    /// True when the first responder is the index list or the search field.
    private var paneHasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        if let table = leadingPane.table, responder.isDescendant(of: table) { return true }
        guard let field = (responder as? NSTextView)?.delegate as? NSTextField else { return false }
        return field === indexSearchField
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

    /// The action of Edit > Find in Session Index and its key.
    func findInIndex() { key?.findInIndex() }
}
