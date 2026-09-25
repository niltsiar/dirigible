import DirigibleAudio
import DirigibleCore
import SwiftUI

/// The timeline side of the session window (decision 0017).
extension SessionWindow {
    /// The narrowed record-over warning of the transport bar (decisions 0016, 0017): Record can
    /// start, and an armed track has a clip at the playhead that is not in view.
    var showsRecordOver: Bool {
        guard canRecord, let studio else { return false }
        return recordOverHidden(
            session: studio.session, armed: armed, playhead: studio.playhead, visible: timeline.visible)
    }
}

extension SessionWindow {
    /// A click in a lane, under 3 pt of movement (decision 0017): Shift selects from the playhead
    /// to the click and the lane joins; Command toggles the lane; a plain click empties the Marks
    /// and seeks.
    func timelineClick(at frame: Frames, lane: Int, shift: Bool, command: Bool) {
        guard let studio, studio.session.tracks.indices.contains(lane) else { return }
        let track = studio.session.tracks[lane].id
        if shift {
            timeline.marks = timeline.marks.extended(to: frame, lane: track, playhead: studio.playhead)
        } else if command {
            timeline.marks = timeline.marks.toggled(track)
        } else {
            timeline.marks = Marks()
            Task { await studio.perform(.seek(.frame(frame))) }
        }
    }

    /// A drag in the lanes: the range from the mouse-down frame to the pointer, on the lanes that
    /// the drag spans.
    func timelineDrag(from: Frames, to: Frames, lanes: (Int, Int)) {
        guard let studio else { return }
        timeline.marks = Marks.drag(from: from, to: to, lanes: lanes, in: studio.session)
    }

    /// A click on the ruler seeks. The Marks do not change.
    func rulerClick(at frame: Frames) {
        guard let studio else { return }
        Task { await studio.perform(.seek(.frame(frame))) }
    }
}

/// A timeline command of the View and Edit menus (decision 0017). Esc is `cancelOperation(_:)`
/// and Select All is the system item; both reach `UndoRoutingWindow`.
enum TimelineCommand: Hashable {
    case zoomIn, zoomOut, zoomToSession, zoomToSelection, toggleFollow
    case setIn, setOut, deselectAll, selectAll

    struct MenuItem {
        let command: TimelineCommand
        let title: L10n
        let key: KeyEquivalent
        let modifiers: EventModifiers
    }

    /// The View items. The menus are built from these tables, and each item has a key (F16).
    static let viewItems = [
        MenuItem(command: .zoomIn, title: .menuViewZoomIn, key: "+", modifiers: .command),
        MenuItem(command: .zoomOut, title: .menuViewZoomOut, key: "-", modifiers: .command),
        MenuItem(command: .zoomToSession, title: .menuViewZoomFit, key: "0", modifiers: .command),
        MenuItem(command: .zoomToSelection, title: .menuViewZoomSelection, key: "h", modifiers: []),
        MenuItem(command: .toggleFollow, title: .menuViewFollow, key: "f", modifiers: [.command, .option]),
    ]

    /// The Edit items after the system items.
    static let editItems = [
        MenuItem(command: .setIn, title: .menuEditIn, key: "i", modifiers: []),
        MenuItem(command: .setOut, title: .menuEditOut, key: "o", modifiers: []),
        MenuItem(command: .deselectAll, title: .menuEditDeselect, key: "a", modifiers: [.command, .shift]),
    ]
}

extension SessionWindow {
    /// Runs a timeline command on this window.
    func run(_ command: TimelineCommand) {
        guard let studio else { return }
        switch command {
        case .zoomIn: timelineView?.zoom(by: 0.5)
        case .zoomOut: timelineView?.zoom(by: 2)
        case .zoomToSession: timelineView?.zoomToSession()
        case .zoomToSelection: timelineView?.zoomToSelection()
        case .toggleFollow:
            timeline.follows.toggle()
            timeline.followHeld = false
            if timeline.follows { timelineView?.showPlayhead() }
        case .setIn: timeline.marks = timeline.marks.settingIn(studio.playhead, in: studio.session)
        case .setOut: timeline.marks = timeline.marks.settingOut(studio.playhead, in: studio.session)
        case .deselectAll: timeline.marks = Marks()
        case .selectAll: timeline.marks = Marks.all(in: studio.session)
        }
    }
}
