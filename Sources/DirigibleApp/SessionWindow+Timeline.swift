import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import SwiftUI

/// The timeline side of the session window (decision 0017).
extension SessionWindow {
    /// The record-over warning (decisions 0016, 0017): Record can start, and it can reach a clip on
    /// an armed track that is not in view.
    var showsRecordOver: RecordOverWarning {
        guard canRecord, let studio else { return RecordOverWarning() }
        return recordOverHidden(
            session: studio.session, armed: armed, playhead: studio.playhead, visible: timeline.visible)
    }
}

extension SessionWindow {
    /// An item of the record-over chip. Each item first saves the typed drafts, as a ruler press
    /// does. Show Clip shows the clip with the first start in the warning, and its lane.
    func recordOver(_ action: RecordOverAction) {
        commitDrafts()
        switch action {
        case .goToEnd: transport(.seek(.end))
        case .turnOffRecord(let track): armed.remove(track)
        case .showClip:
            guard let studio else { return }
            let tracks = studio.session.tracks
            let reached = shown.recordOver.reached.compactMap { reached -> (lane: Int, start: Frames)? in
                guard let lane = tracks.firstIndex(where: { $0.id == reached.track }),
                    let clip = tracks[lane].clips.first(where: { $0.id == reached.clip })
                else { return nil }
                return (lane, clip.start)
            }
            guard let first = reached.min(by: { $0.start < $1.start }) else { return }
            timelineView?.reveal(frame: max(studio.playhead, first.start), lane: first.lane)
        }
    }

    /// The effects of a timeline gesture (decision 0020). A commit makes one undo entry when the
    /// session is still the session of the mouse-down. Else, or during a take, it changes nothing
    /// and shows no alert. Studio refuses a ripple trim under a pending or split take, with a beep.
    func apply(_ effects: [GestureEffect]) {
        guard let studio else { return }
        for effect in effects {
            switch effect {
            case .selection(let selection): timeline.selection = selection
            case .seek(let frame):
                resumeTranscriptFollow()
                Task { await studio.perform(.seek(.frame(frame))) }
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
    case split, nudgeLeft, nudgeRight, fade, heal
    case addMarker, addChapter, markerInfo, moveMarker, deleteMarker, previousMarker, nextMarker
    case renameTrack, removeTrack, muteTracks, soloTracks, showInFinder, importAudio, importTranscript, export,
        exportSelection
    case raiseVolume, lowerVolume, resetVolume
    case exportChapters, exportTranscript, episodeInfo
    case autoLevel, autoLevelPerTrack, duck, splitStereo, reduceNoise, repairSound, restoreOriginal
    case addGainPoint, previousGainPoint, nextGainPoint

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
        // Export Transcript and Import Transcript have no key.
        case .exportTranscript, .importTranscript: false
        case .autoLevel, .autoLevelPerTrack: false
        // Duck Music Under Speech... has no key (plan gate 1 item 3).
        case .duck: false
        // A text field does nothing with Shift-Command-D, so the key splits the stereo clips of the
        // selection with the focus in a track name field, as Insert does with Command-I.
        case .splitStereo: false
        // Reduce Noise has no key: a rare, slow command.
        case .reduceNoise: false
        // Repair Sound has no key: a rare, slow command, as Reduce Noise.
        case .repairSound: false
        // A text field does nothing with Shift-Command-O.
        case .restoreOriginal: false
        // A text field types a symbol with Option-K, Option-;, and Option-'.
        case .addGainPoint, .previousGainPoint, .nextGainPoint: true
        // Probe K1: a focused track name field ignores Command-F, so Fade acts on the selection.
        case .fade: false
        // Heal Clips has no key: Command-H is Hide in macOS.
        case .heal: false
        }
    }

    /// The volume keys stay the typed characters. With the automatic localization, AppKit moved "="
    /// of Raise Track Volume to the "*" key of the Spanish layout, where "=" is Shift-0 (S6 check).
    /// The gain point keys also stay the typed characters: on the Spanish layout, ";" and "'" sit on
    /// other keys than on the US layout.
    var keyLocalization: KeyboardShortcut.Localization {
        switch self {
        case .raiseVolume, .lowerVolume, .resetVolume, .addGainPoint, .previousGainPoint, .nextGainPoint: .custom
        default: .automatic
        }
    }
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
        if startsOrSeeks(command) { resumeTranscriptFollow() }
        transportWork = Task { await studio?.perform(command) }
    }

    /// Returns when the work of the last transport or speed key ends. The playhead of a seek
    /// that stops a play is final only then.
    func settleTransport() async { await transportWork?.value }

    /// A vari-speed change from a key, the menu, or the pop-up (decision 0052). The app owns the
    /// last speed: the window resolves the change to one speed and stores it with no await before
    /// the Studio takes it, so two changes that overlap keep the last pick.
    func speed(_ change: SpeedChange) {
        leafCalls?.append("\(change)")
        commitInspector()
        guard let studio else { return }
        transportWork = Task {
            let target = change.target(from: studio.speed, last: app?.lastSpeed ?? .x150)
            if target != .one, studio.takesSpeedChange { app?.lastSpeed = target }
            await studio.changeSpeed(to: target)
        }
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
        case .heal: runHeal(studio)
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
        case .importTranscript: chooseTranscriptImport()
        case .export: Task { await export(.session) }
        case .exportSelection: Task { await export(.selection) }
        case .exportChapters: exportChapters()
        case .exportTranscript: exportTranscript()
        case .episodeInfo: showEpisodeInfo()
        case .addGainPoint, .previousGainPoint, .nextGainPoint: runGainPoint(command, studio)
        case .autoLevel: Task { await level(.eachClip) }
        case .autoLevelPerTrack: Task { await level(.equallyPerTrack) }
        case .duck: startDuck()
        case .splitStereo: splitStereo()
        case .reduceNoise: reduceNoise()
        case .repairSound: repairSound()
        case .restoreOriginal: restoreOriginal()
        }
    }
}
