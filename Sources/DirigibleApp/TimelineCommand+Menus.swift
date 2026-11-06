import SwiftUI

/// The menu tables of the timeline commands (decisions 0017, 0018).
extension TimelineCommand {
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
    /// Cut, Delete and Close Gap, Insert, and Replace ripple all tracks (decisions 0037 and 0053).
    static let pasteboardItems = [
        MenuItem(command: .cut, title: .menuEditCut, key: "x", modifiers: .command),
        MenuItem(command: .copy, title: .menuEditCopy, key: "c", modifiers: .command),
        MenuItem(command: .paste, title: .menuEditPaste, key: "v", modifiers: .command),
        MenuItem(command: .fill, title: .menuEditFill, key: "v", modifiers: [.command, .option]),
        MenuItem(command: .insert, title: .menuEditInsert, key: "i", modifiers: .command),
        MenuItem(command: .replace, title: .menuEditReplace, key: "v", modifiers: [.command, .shift]),
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
        MenuItem(command: .rollToPlayhead, title: .menuEditRollToPlayhead, key: "x", modifiers: .shift),
        MenuItem(
            command: .slipLeft, title: .menuEditSlipContentLeft, key: .leftArrow, modifiers: [.shift, .option]),
        MenuItem(
            command: .slipRight, title: .menuEditSlipContentRight, key: .rightArrow, modifiers: [.shift, .option]),
        MenuItem(command: .fade, title: .menuEditFade, key: "f", modifiers: .command),
        MenuItem(command: .addGainPoint, title: .menuEditAddGainPoint, key: "k", modifiers: .option),
    ]

    /// The Transport items that move the playhead to a gain point (decision 0060).
    static let gainPointSeekItems = [
        MenuItem(command: .previousGainPoint, title: .menuTransportPreviousGainPoint, key: ";", modifiers: .option),
        MenuItem(command: .nextGainPoint, title: .menuTransportNextGainPoint, key: "'", modifiers: .option),
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

    /// Tools > Split Stereo to Mono (decision 0053): its own group at the end of the Tools menu.
    static let splitStereoItem = MenuItem(
        command: .splitStereo, title: .menuToolsSplitStereo, key: "d", modifiers: [.command, .shift])

    /// The title of a menu item with no key; the lane menu reads it as it reads `menuItems`.
    static let keylessTitles: [TimelineCommand: L10n] = [
        .reduceNoise: .menuToolsReduceNoise, .repairSound: .menuToolsRepairSound, .transcribe: .menuToolsTranscribe,
        .closeGaps: .menuEditCloseGaps,
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
