/// What a timeline command does while the focus is in the index list.
extension TimelineCommand {
    enum IndexFocus {
        /// The command acts on the selected rows, as the list rules say.
        case rows
        /// A beep: the command reads the selection, the Marks, or the tracks that the list does not show.
        case beep
        /// The command runs as in the lanes.
        case lanes
    }

    var indexFocus: IndexFocus {
        switch self {
        case .renameTrack, .markerInfo, .delete, .selectAll, .deselectAll, .addMarker, .addChapter, .deleteMarker,
            .moveMarker:
            .rows
        case .cut, .copy, .paste, .fill, .insert, .replace, .deleteCloseGap, .deleteCloseGapSelectedTracks,
            .cutSelectedTracks, .split, .nudgeLeft, .nudgeRight, .fade, .heal, .closeGaps, .rollToPlayhead, .slipLeft,
            .slipRight, .addGainPoint, .removeTrack, .muteTracks, .soloTracks, .raiseVolume, .lowerVolume,
            .resetVolume, .autoLevel, .autoLevelPerTrack, .levelOverTime, .removeLevelOverTime, .duck, .splitStereo,
            .reduceNoise, .repairSound, .restoreOriginal, .transcribe, .useAsVoiceReference, .syncClip:
            .beep
        case .zoomIn, .zoomOut, .zoomToSession, .zoomToSelection, .zoomBack, .zoomForward, .pagePrevious, .pageNext,
            .toggleFollow, .tallerTracks, .shorterTracks, .fitTracks, .waveformZoomIn, .waveformZoomOut,
            .waveformZoomReset, .setIn, .setOut, .previousMarker, .nextMarker,
            .previousGainPoint, .nextGainPoint, .showInFinder, .importAudio, .importTranscript, .export,
            .exportSelection, .exportChapters, .exportStems, .exportTranscript, .episodeInfo, .findSilences:
            .lanes
        }
    }
}
