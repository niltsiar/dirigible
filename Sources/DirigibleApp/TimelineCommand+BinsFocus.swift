/// What a timeline command does while the focus is in the Bins list (C23).
extension TimelineCommand {
    enum BinsFocus {
        /// The command acts on the selected item: Command-Return pastes, Shift-Return inserts, Return
        /// renames, and Delete removes it.
        case item
        /// A beep: the command edits the tracks or the markers, and the list hides the timeline selection.
        case beep
        /// The command runs as in the lanes.
        case lanes
    }

    var binsFocus: BinsFocus {
        switch self {
        case .addMarker, .markerInfo, .renameTrack, .delete: .item
        case .cut, .copy, .paste, .fill, .insert, .replace, .deleteCloseGap, .deleteCloseGapSelectedTracks,
            .cutSelectedTracks, .split, .nudgeLeft, .nudgeRight, .fade, .heal, .closeGaps, .rollToPlayhead, .slipLeft,
            .slipRight, .addGainPoint, .removeTrack, .muteTracks, .soloTracks, .raiseVolume, .lowerVolume,
            .resetVolume, .autoLevel, .autoLevelPerTrack, .levelOverTime, .removeLevelOverTime, .duck, .splitStereo,
            .reduceNoise, .repairSound, .restoreOriginal, .transcribe, .useAsVoiceReference, .syncClip, .selectAll,
            .deselectAll, .addChapter, .deleteMarker, .moveMarker, .duckSelection:
            .beep
        case .zoomIn, .zoomOut, .zoomToSession, .zoomToSelection, .zoomBack, .zoomForward, .pagePrevious, .pageNext,
            .toggleFollow, .tallerTracks, .shorterTracks, .fitTracks, .waveformZoomIn, .waveformZoomOut,
            .waveformZoomReset, .setIn, .setOut, .previousMarker, .nextMarker,
            .previousGainPoint, .nextGainPoint, .showInFinder, .importAudio, .importTranscript, .importSession,
            .export, .exportSelection, .exportChapters, .exportStems, .exportPresets, .exportTranscript, .episodeInfo,
            .findSilences:
            .lanes
        }
    }
}
