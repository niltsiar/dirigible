import AppKit
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
    @ObservationIgnored weak var table: NSTableView?
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
