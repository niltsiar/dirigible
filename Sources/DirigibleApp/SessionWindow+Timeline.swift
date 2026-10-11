import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import SwiftUI

/// The timeline side of the session window (decision 0017).
extension SessionWindow {
    /// The record-over overlay (decisions 0016, 0017): Record can start, and it can reach a clip on
    /// an armed track that is not in view.
    var showsRecordOver: Bool {
        guard canRecord, let studio else { return false }
        return recordOverHidden(
            session: studio.session, armed: armed, playhead: studio.playhead, visible: timeline.visible)
    }
}

extension SessionWindow {
    /// The effects of a timeline gesture (decision 0020). A commit makes one undo entry when the
    /// session is still the session of the mouse-down. Else, or during a take, it changes nothing
    /// and shows no alert. Studio refuses a ripple trim under a pending or split take, with a beep.
    func apply(_ effects: [GestureEffect]) {
        guard let studio else { return }
        for effect in effects {
            switch effect {
            case .selection(let selection): timeline.selection = selection
            case .seek(let frame): Task { await studio.perform(.seek(.frame(frame))) }
            case .currentMarker(let id): timeline.marker = id
            case .beep: beep()
            case .commit(let commit):
                guard edit(ripple: commit.ripple, { session in commit.apply(to: &session) }) == true else { continue }
                if let selection = commit.selection { timeline.selection = selection }
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
    /// The ripple items of decision 0037: Delete and Close Gap, Insert, and the two twins that
    /// ripple only the selected tracks. Cut closes the gap too.
    case deleteCloseGap, insert, cutSelectedTracks, deleteCloseGapSelectedTracks
    case split, nudgeLeft, nudgeRight, fade
    case addMarker, addChapter, markerInfo, moveMarker, deleteMarker, previousMarker, nextMarker
    case renameTrack, removeTrack, muteTracks, soloTracks, showInFinder, importAudio, export, exportSelection
    case raiseVolume, lowerVolume, resetVolume
    case exportChapters, episodeInfo
    case autoLevel, autoLevelPerTrack

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
        // Shift-Backspace and Option-Shift-Backspace delete text in a field (0018 K3).
        case .deleteCloseGap, .deleteCloseGapSelectedTracks: true
        // A text field does nothing with Command-I or Option-Command-X (probe K5 of run 12).
        case .insert, .cutSelectedTracks: false
        // A text field moves the caret to its start or end with Command-Up and Command-Down.
        case .tallerTracks, .shorterTracks: true
        case .fitTracks: false
        case .addMarker, .addChapter, .markerInfo, .moveMarker, .deleteMarker, .previousMarker, .nextMarker: true
        // A focused text field ends its edit with Return.
        case .renameTrack, .removeTrack, .showInFinder: true
        // A focused text field types the capital letter of Shift-M and Shift-S.
        case .muteTracks, .soloTracks: true
        // A text field does nothing with Control-=, Control-minus, or Control-0.
        case .raiseVolume, .lowerVolume, .resetVolume: false
        case .zoomIn, .zoomOut, .zoomToSession, .zoomBack, .zoomForward, .pagePrevious, .pageNext, .toggleFollow: false
        case .deselectAll, .selectAll, .cut, .copy, .paste: false
        // A text field does nothing with Command-T (run 13a, C9).
        case .importAudio, .export, .exportSelection, .exportChapters, .episodeInfo: false
        case .autoLevel, .autoLevelPerTrack: false
        // Probe K1: a focused track name field ignores Command-F, so Fade acts on the selection.
        case .fade: false
        }
    }

    /// The volume keys stay the typed characters. With the automatic localization, AppKit moved "="
    /// of Raise Track Volume to the "*" key of the Spanish layout, where "=" is Shift-0 (S6 check).
    var keyLocalization: KeyboardShortcut.Localization {
        switch self {
        case .raiseVolume, .lowerVolume, .resetVolume: .custom
        default: .automatic
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
    /// Cut, Delete and Close Gap, and Insert ripple all tracks (decision 0037).
    static let pasteboardItems = [
        MenuItem(command: .cut, title: .menuEditCut, key: "x", modifiers: .command),
        MenuItem(command: .copy, title: .menuEditCopy, key: "c", modifiers: .command),
        MenuItem(command: .paste, title: .menuEditPaste, key: "v", modifiers: .command),
        MenuItem(command: .insert, title: .menuEditInsert, key: "i", modifiers: .command),
        MenuItem(command: .delete, title: .menuEditDelete, key: .delete, modifiers: []),
        MenuItem(command: .deleteCloseGap, title: .menuEditDeleteCloseGap, key: .delete, modifiers: .shift),
        MenuItem(command: .selectAll, title: .menuEditSelectAll, key: "a", modifiers: .command),
    ]

    /// The twins that ripple only the selected tracks, in their own Edit group (decision 0037).
    static let rippleItems = [
        MenuItem(
            command: .cutSelectedTracks, title: .menuEditCutSelectedTracks, key: "x", modifiers: [.command, .option]),
        MenuItem(
            command: .deleteCloseGapSelectedTracks, title: .menuEditDeleteCloseGapSelectedTracks, key: .delete,
            modifiers: [.shift, .option]),
    ]

    /// The Edit items after the pasteboard items.
    static let editItems = [
        MenuItem(command: .setIn, title: .menuEditIn, key: "i", modifiers: []),
        MenuItem(command: .setOut, title: .menuEditOut, key: "o", modifiers: []),
        MenuItem(command: .deselectAll, title: .menuEditDeselect, key: "a", modifiers: [.command, .shift]),
        MenuItem(command: .split, title: .menuEditSplit, key: "b", modifiers: .command),
        MenuItem(command: .nudgeLeft, title: .menuEditNudgeLeft, key: .leftArrow, modifiers: .command),
        MenuItem(command: .nudgeRight, title: .menuEditNudgeRight, key: .rightArrow, modifiers: .command),
        MenuItem(command: .fade, title: .menuEditFade, key: "f", modifiers: .command),
    ]

    /// The Markers items (decision 0018). Each key is one that a text field uses, so each item
    /// forwards it first.
    static let markerItems = [
        MenuItem(command: .addMarker, title: .menuMarkersAdd, key: .return, modifiers: .command),
        MenuItem(command: .addChapter, title: .menuMarkersAddChapter, key: .return, modifiers: [.command, .shift]),
        MenuItem(command: .markerInfo, title: .menuMarkersInfo, key: .return, modifiers: .shift),
        MenuItem(command: .moveMarker, title: .menuMarkersMove, key: .return, modifiers: [.command, .option]),
        MenuItem(command: .deleteMarker, title: .menuMarkersDelete, key: .delete, modifiers: .command),
        MenuItem(command: .previousMarker, title: .menuMarkersPrevious, key: .pageUp, modifiers: []),
        MenuItem(command: .nextMarker, title: .menuMarkersNext, key: .pageDown, modifiers: []),
    ]

    /// The Rename Track, Remove Track, Mute Track, Solo Track, and track volume items of the Track
    /// menu. The volume keys are the keys of Final Cut Pro. The Spanish Control-Shift-0 types "=",
    /// so it reaches Raise Track Volume (`TrackVolumeKeyTests`).
    static let trackItems = [
        MenuItem(command: .renameTrack, title: .menuTrackRename, key: .return, modifiers: []),
        MenuItem(command: .removeTrack, title: .menuTrackRemove, key: .delete, modifiers: [.command, .option]),
        MenuItem(command: .muteTracks, title: .menuTrackMute, key: "m", modifiers: .shift),
        MenuItem(command: .soloTracks, title: .menuTrackSolo, key: "s", modifiers: .shift),
        MenuItem(command: .raiseVolume, title: .menuTrackVolumeUp, key: "=", modifiers: .control),
        MenuItem(command: .lowerVolume, title: .menuTrackVolumeDown, key: "-", modifiers: .control),
        MenuItem(command: .resetVolume, title: .menuTrackVolumeReset, key: "0", modifiers: .control),
    ]

    /// The Tools items (decision 0031).
    static let toolItems = [
        MenuItem(command: .autoLevel, title: .menuToolsLevel, key: "l", modifiers: .command),
        MenuItem(command: .autoLevelPerTrack, title: .menuToolsLevelTrack, key: "l", modifiers: [.command, .option]),
    ]

    /// The Import Audio, Show Clips in Finder, Export, Export Selection, and Export Chapters items of the
    /// File menu.
    /// Import Audio has Command-T, as File > Import of Hindenburg (decision 0040).
    static let fileItems = [
        MenuItem(command: .importAudio, title: .menuFileImport, key: "t", modifiers: .command),
        MenuItem(command: .showInFinder, title: .menuFileShowClips, key: "r", modifiers: [.command, .shift]),
        MenuItem(command: .export, title: .menuFileExport, key: "e", modifiers: .command),
        MenuItem(command: .exportSelection, title: .menuFileExportSelection, key: "e", modifiers: [.command, .shift]),
        MenuItem(command: .exportChapters, title: .menuFileExportChapters, key: "e", modifiers: [.command, .option]),
        MenuItem(command: .episodeInfo, title: .menuFileEpisodeInfo, key: "i", modifiers: [.command, .shift]),
    ]
}

extension SessionWindow {
    /// The toolbar entry (decision 0023): each command goes to the place that its menu item
    /// reaches. The generic menu entry run(_:) and the Transport menu commit only the inspector
    /// value; Remove Track drops the name drafts of its tracks. An import and a paste from another
    /// package commit the names too, before their blocking run (`commitDrafts`).
    func run(_ command: WindowCommand) {
        switch command {
        case .timeline(let command): run(command)
        case .transport(let command): transport(command)
        case .addTrack, .record, .stop, .toggleMonitor, .toggleInspector, .toggleSnap:
            // The menu items of the window actions call this function too.
            leafCalls?.append("\(command)")
            switch command {
            case .addTrack:
                commitInspector()
                addTrack()
            case .record: Task { await record() }
            case .stop: Task { await stopOrPause() }
            case .toggleInspector: toggleInspector()
            case .toggleSnap: app?.toggleSnap()
            default: monitoring.toggle()
            }
        }
    }

    /// A transport command: the Transport menu and the toolbar come here (decision 0016).
    func transport(_ command: TransportCommand) {
        leafCalls?.append("\(command)")
        commitInspector()
        Task { await studio?.perform(command) }
    }

    /// Stop and Command-period: a take stops and finalizes, else the play stops and keeps the
    /// playhead (decision 0023).
    func stopOrPause() async {
        if canStop { await stop() } else { await studio?.perform(.pause) }
    }

    /// View > Snap, the app preference: the one predicate of the gesture context and the toolbar.
    var snaps: Bool { app?.snaps == true }

    /// Runs a timeline command on this window.
    func run(_ command: TimelineCommand) {
        leafCalls?.append("\(command)")
        commitInspector()
        guard let studio else { return }
        switch command {
        case .zoomIn: timelineView?.navigate(.zoom(by: 0.5))
        case .zoomOut: timelineView?.navigate(.zoom(by: 2))
        case .zoomToSession: timelineView?.navigate(.fitSession)
        case .zoomToSelection:
            timelineView?.navigate(.toggleSelection(timeline.selection.span(in: studio.session)))
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
        case .setIn: timeline.selection = .range(timeline.selection.settingIn(studio.playhead, in: studio.session))
        case .setOut: timeline.selection = .range(timeline.selection.settingOut(studio.playhead, in: studio.session))
        case .deselectAll:
            timeline.selection = .none
            timeline.marker = nil
        case .selectAll: timeline.selection = .range(Marks.all(in: studio.session))
        case .copy, .paste, .delete: runClipboard(command, studio)
        case .cut, .deleteCloseGap, .insert, .cutSelectedTracks, .deleteCloseGapSelectedTracks:
            runRipple(command, studio)
        case .split, .nudgeLeft, .nudgeRight: runSplitOrNudge(command, studio)
        case .fade: runFade(studio)
        case .addMarker, .addChapter, .markerInfo, .moveMarker, .deleteMarker, .previousMarker, .nextMarker:
            runMarker(command, studio)
        case .renameTrack:
            // The first track that the headers show as selected; a clip set picks no track.
            guard let track = timeline.selection.headerTracks(in: studio.session).first else { return beep() }
            startRename(track)
        case .removeTrack:
            // A clip set picks clips, not tracks: Remove Track does nothing (decision 0038).
            removeTracks(timeline.selection.headerTracks(in: studio.session))
        case .muteTracks: toggleFlag(.muted)
        case .soloTracks: toggleFlag(.soloed)
        case .raiseVolume, .lowerVolume, .resetVolume: changeVolume(command, studio)
        case .showInFinder: Task { await showClipsInFinder() }
        case .importAudio: chooseImport()
        case .export: Task { await export(.session) }
        case .exportSelection: Task { await export(.selection) }
        case .exportChapters: exportChapters()
        case .episodeInfo: showEpisodeInfo()
        case .autoLevel: Task { await level(.eachClip) }
        case .autoLevelPerTrack: Task { await level(.equallyPerTrack) }
        }
    }
}
