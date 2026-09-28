import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
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
    /// The effects of a timeline gesture (decision 0020). A commit makes one undo entry when the
    /// session is still the session of the mouse-down. Else, or during a take, it changes nothing
    /// and shows no alert.
    func apply(_ effects: [GestureEffect]) {
        guard let studio else { return }
        for effect in effects {
            switch effect {
            case .marks(let marks): timeline.marks = marks
            case .seek(let frame): Task { await studio.perform(.seek(.frame(frame))) }
            case .currentMarker(let id): timeline.marker = id
            case .commit(let commit):
                guard edit({ session in commit.apply(to: &session) }) == true else { continue }
                if let marks = commit.marks { timeline.marks = marks }
                if let marker = commit.marker { timeline.marker = marker }
            }
        }
    }
}

/// A timeline command of the View and Edit menus (decisions 0017, 0018). Esc is
/// `cancelOperation(_:)` and reaches `UndoRoutingWindow`.
enum TimelineCommand: Hashable {
    case zoomIn, zoomOut, zoomToSession, zoomToSelection, zoomBack, zoomForward, pagePrevious, pageNext, toggleFollow
    case tallerTracks, shorterTracks, fitTracks
    case setIn, setOut, deselectAll, selectAll
    case cut, copy, paste, delete
    case split, nudgeLeft, nudgeRight
    case addMarker, addChapter, renameMarker, moveMarker, deleteMarker, previousMarker, nextMarker
    case removeTrack, showInFinder, export, exportSelection

    /// The selector of an item of the replaced Edit group. The item sends it from the first
    /// responder of the key window, so a focused text field takes it before the window (probe E3).
    var selector: Selector? {
        switch self {
        case .cut: #selector(NSText.cut(_:))
        case .copy: #selector(NSText.copy(_:))
        case .paste: #selector(NSText.paste(_:))
        case .delete: #selector(NSText.delete(_:))
        case .selectAll: #selector(NSResponder.selectAll(_:))
        default: nil
        }
    }

    /// True when a focused text field uses the key of the item (probes E4b, K1): the item gives
    /// the key-down to the field first. Cut, Copy, Paste, and Select All need no forward, because
    /// their selector reaches the field (probe E3).
    var forwardsKey: Bool {
        switch self {
        case .zoomToSelection, .setIn, .setOut, .delete, .split, .nudgeLeft, .nudgeRight: true
        // A text field moves the caret to its start or end with Command-Up and Command-Down.
        case .tallerTracks, .shorterTracks: true
        case .fitTracks: false
        case .addMarker, .addChapter, .renameMarker, .moveMarker, .deleteMarker, .previousMarker, .nextMarker: true
        case .removeTrack, .showInFinder: true
        case .zoomIn, .zoomOut, .zoomToSession, .zoomBack, .zoomForward, .pagePrevious, .pageNext, .toggleFollow: false
        case .deselectAll, .selectAll, .cut, .copy, .paste: false
        case .export, .exportSelection: false
        }
    }

    struct MenuItem {
        let command: TimelineCommand
        let title: L10n
        let key: KeyEquivalent
        let modifiers: EventModifiers
    }

    /// The View items in groups; the menu has a separator between two groups (U6). The menus are
    /// built from these tables, and each item has a key (F16).
    static let viewGroups = [
        [
            MenuItem(command: .zoomIn, title: .menuViewZoomIn, key: "+", modifiers: .command),
            MenuItem(command: .zoomOut, title: .menuViewZoomOut, key: "-", modifiers: .command),
            MenuItem(command: .zoomToSession, title: .menuViewZoomFit, key: "0", modifiers: .command),
            MenuItem(command: .zoomToSelection, title: .menuViewZoomSelection, key: "h", modifiers: []),
        ],
        [
            MenuItem(command: .zoomBack, title: .menuViewZoomBack, key: .leftArrow, modifiers: [.command, .option]),
            MenuItem(
                command: .zoomForward, title: .menuViewZoomForward, key: .rightArrow, modifiers: [.command, .option]),
        ],
        [
            MenuItem(command: .pagePrevious, title: .menuViewPagePrevious, key: .pageUp, modifiers: .option),
            MenuItem(command: .pageNext, title: .menuViewPageNext, key: .pageDown, modifiers: .option),
        ],
        [
            MenuItem(command: .tallerTracks, title: .menuViewTracksTaller, key: .downArrow, modifiers: .command),
            MenuItem(command: .shorterTracks, title: .menuViewTracksShorter, key: .upArrow, modifiers: .command),
        ],
        [MenuItem(command: .toggleFollow, title: .menuViewFollow, key: "f", modifiers: [.command, .option])],
    ]
    /// Fit Tracks to Window has no key (U2), so it is not in these keyed tables: the View menu adds
    /// it after the track group.
    static let viewItems = viewGroups.flatMap { $0 }

    /// The items that replace the system pasteboard group (probe E6). Delete has Backspace (F16).
    static let pasteboardItems = [
        MenuItem(command: .cut, title: .menuEditCut, key: "x", modifiers: .command),
        MenuItem(command: .copy, title: .menuEditCopy, key: "c", modifiers: .command),
        MenuItem(command: .paste, title: .menuEditPaste, key: "v", modifiers: .command),
        MenuItem(command: .delete, title: .menuEditDelete, key: .delete, modifiers: []),
        MenuItem(command: .selectAll, title: .menuEditSelectAll, key: "a", modifiers: .command),
    ]

    /// The Edit items after the pasteboard items.
    static let editItems = [
        MenuItem(command: .setIn, title: .menuEditIn, key: "i", modifiers: []),
        MenuItem(command: .setOut, title: .menuEditOut, key: "o", modifiers: []),
        MenuItem(command: .deselectAll, title: .menuEditDeselect, key: "a", modifiers: [.command, .shift]),
        MenuItem(command: .split, title: .menuEditSplit, key: "b", modifiers: .command),
        MenuItem(command: .nudgeLeft, title: .menuEditNudgeLeft, key: .leftArrow, modifiers: .command),
        MenuItem(command: .nudgeRight, title: .menuEditNudgeRight, key: .rightArrow, modifiers: .command),
    ]

    /// The Markers items (decision 0018). Each key is one that a text field uses, so each item
    /// forwards it first.
    static let markerItems = [
        MenuItem(command: .addMarker, title: .menuMarkersAdd, key: .return, modifiers: .command),
        MenuItem(command: .addChapter, title: .menuMarkersAddChapter, key: .return, modifiers: [.command, .shift]),
        MenuItem(command: .renameMarker, title: .menuMarkersRename, key: .return, modifiers: .shift),
        MenuItem(command: .moveMarker, title: .menuMarkersMove, key: .return, modifiers: [.command, .option]),
        MenuItem(command: .deleteMarker, title: .menuMarkersDelete, key: .delete, modifiers: .command),
        MenuItem(command: .previousMarker, title: .menuMarkersPrevious, key: .pageUp, modifiers: []),
        MenuItem(command: .nextMarker, title: .menuMarkersNext, key: .pageDown, modifiers: []),
    ]

    /// The Remove Track item of the Track menu.
    static let trackItems = [
        MenuItem(command: .removeTrack, title: .menuTrackRemove, key: .delete, modifiers: [.command, .option])
    ]

    /// The Show Clips in Finder, Export, and Export Selection items of the File menu.
    static let fileItems = [
        MenuItem(command: .showInFinder, title: .menuFileShowClips, key: "r", modifiers: [.command, .shift]),
        MenuItem(command: .export, title: .menuFileExport, key: "e", modifiers: .command),
        MenuItem(command: .exportSelection, title: .menuFileExportSelection, key: "e", modifiers: [.command, .shift]),
    ]
}

extension SessionWindow {
    /// The toolbar entry (decision 0023): each command goes to the place that its menu item
    /// reaches.
    func run(_ command: WindowCommand) {
        switch command {
        case .timeline(let command): run(command)
        case .transport(let command): transport(command)
        case .addTrack, .record, .stop, .toggleMonitor:
            // The menu items of the window actions call this function too.
            leafCalls?.append("\(command)")
            switch command {
            case .addTrack: addTrack()
            case .record: Task { await record() }
            case .stop: Task { await stopOrPause() }
            default: monitoring.toggle()
            }
        }
    }

    /// A transport command: the Transport menu and the toolbar come here (decision 0016).
    func transport(_ command: TransportCommand) {
        leafCalls?.append("\(command)")
        Task { await studio?.perform(command) }
    }

    /// Stop and Command-period: a take stops and finalizes, else the play stops and keeps the
    /// playhead (decision 0023).
    func stopOrPause() async {
        if canStop { await stop() } else { await studio?.perform(.pause) }
    }

    /// Runs a timeline command on this window.
    func run(_ command: TimelineCommand) {
        leafCalls?.append("\(command)")
        guard let studio else { return }
        switch command {
        case .zoomIn: timelineView?.navigate(.zoom(by: 0.5))
        case .zoomOut: timelineView?.navigate(.zoom(by: 2))
        case .zoomToSession: timelineView?.navigate(.fitSession)
        case .zoomToSelection:
            timelineView?.navigate(.toggleSelection(timeline.marks.selection(in: studio.session)?.range))
        case .zoomBack: timelineView?.navigate(.back)
        case .zoomForward: timelineView?.navigate(.forward)
        case .pagePrevious: timelineView?.navigate(.page(.backward))
        case .pageNext: timelineView?.navigate(.page(.forward))
        case .tallerTracks, .shorterTracks, .fitTracks:
            // A lane gesture keeps the lane rows of its preview until the mouse-up (0025).
            guard timelineView?.gesture.isActive != true else { return }
            let shown = timelineView?.lanes.inputs?.laneHeight ?? 100
            switch command {
            case .tallerTracks: timeline.laneHeight = timeline.laneHeight.taller(than: shown)
            case .shorterTracks: timeline.laneHeight = timeline.laneHeight.shorter(than: shown)
            default: timeline.laneHeight = .automatic
            }
        case .toggleFollow:
            timeline.follows.toggle()
            timeline.followHeld = false
            if timeline.follows { timelineView?.showPlayhead() }
        case .setIn: timeline.marks = timeline.marks.settingIn(studio.playhead, in: studio.session)
        case .setOut: timeline.marks = timeline.marks.settingOut(studio.playhead, in: studio.session)
        case .deselectAll:
            timeline.marks = Marks()
            timeline.marker = nil
        case .selectAll: timeline.marks = Marks.all(in: studio.session)
        case .cut, .copy, .paste, .delete: runClipboard(command, studio)
        case .split, .nudgeLeft, .nudgeRight: runSplitOrNudge(command, studio)
        case .addMarker, .addChapter, .renameMarker, .moveMarker, .deleteMarker, .previousMarker, .nextMarker:
            runMarker(command, studio)
        case .removeTrack: removeTracks(studio.session.tracks.map(\.id).filter(timeline.marks.tracks.contains))
        case .showInFinder: Task { await showClipsInFinder() }
        case .export: Task { await export(.session) }
        case .exportSelection: Task { await export(.selection) }
        }
    }
}
