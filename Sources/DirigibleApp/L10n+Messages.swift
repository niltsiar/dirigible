import DirigibleAudio
import DirigibleCore
import Foundation
import UniformTypeIdentifiers

/// The texts of library errors.
extension L10n {
    /// A byte count in the units of the Finder.
    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    /// The text of a library error. The switches have no `default`, so a new error case does not
    /// compile until it has a key. `session` gives the track names; without it, the text shows
    /// the track ID.
    static func message(for error: StudioError, session: Session? = nil) -> String {
        let name = { (id: TrackID) in session?.track(id)?.name ?? id.rawValue }
        switch error {
        case .busy: return errorBusy.text
        case .locked: return errorLocked.text
        case .noRoute(let track): return errorNoRoute.format(name(track))
        case .deviceMissing(let track): return errorDeviceMissing.format(name(track))
        case .channelOutOfRange(let track): return errorChannelOutOfRange.format(name(track))
        case .channelInUse(let first, let second): return errorChannelInUse.format(name(first), name(second))
        case .diskLow: return errorDiskLow.text
        case .appSourcesUnavailable: return errorAppSourcesUnavailable.text
        case .placementSpace(let needed, let free):
            return errorPlacementSpace.format(bytes(needed), bytes(free))
        case .microphoneAccess(.restricted): return errorMicrophoneRestricted.text
        case .microphoneAccess(.denied), .microphoneAccess(.notDetermined): return errorMicrophoneDenied.text
        case .session(let error): return message(for: error, name: name)
        case .file(let error): return message(for: error)
        case .finalize(.readFailed(let file, let errno)): return errorFinalizeRead.format(file, Int(errno))
        case .finalize(.writeFailed(let file, let status)): return errorFinalizeWrite.format(file, Int(status))
        case .finalize(.segmentUnreadable(_, let file, let errno)):
            return errorFinalizeUnreadable.format(file, Int(errno))
        case .export(let error): return message(for: error)
        case .exportYielded: return errorExportYielded.text
        case .exportParts(.exists): return errorExportExists.text
        case .exportParts(.noPoint(let kind, _)):
            return (kind == .chapters ? errorExportNoChapter : errorExportNoMarker).text
        case .exportParts(.stopped(let stop)):
            let count = stop.written.count + stop.remaining.count
            return message(for: stop.error) + "\n\n" + bannerExportSetStopped.format(stop.written.count, count)
        case .audioImport(.session(let error)): return message(for: error, name: name)
        case .audioImport(let error): return message(for: error)
        case .importYielded(let file): return errorImportYielded.format(file)
        case .paste(.session(let error), _): return message(for: error, name: name)
        case .paste(let error, let source): return message(for: error, source: source)
        case .pasteYielded(let source): return errorPasteYielded.format(source)
        case .split(.session(let error)): return message(for: error, name: name)
        case .split(let error): return message(for: error)
        case .splitYielded: return errorSplitYielded.text
        case .clipRender(.session(let error)): return message(for: error, name: name)
        case .clipRender(let error): return message(for: error)
        case .clipRenderYielded: return errorDenoiseYielded.text
        // The window beeps for it and shows no alert.
        case .rippleBlocked: return errorSessionOther.text
        // The banner Cancel ends a level or a duck, so the window shows no alert for it (decision 0049).
        // Only an agent read gives `readYielded` and `readClosed`, and the agent gets its text (decision 0062).
        case .levelCancelled, .duckCancelled, .readYielded, .readClosed: return errorSessionOther.text
        // The window shows no alert for a stop or a cancel: the banner and the announcement say it.
        case .transcriptionYielded: return transcribeStopped.text
        case .transcriptionCancelled: return transcribeCanceled.text
        case .transcription(let error): return message(for: error)
        case .duckRead(let code): return errorDuckRead.format(Int(code))
        // The banner Cancel ends a silence scan, so the window shows no alert for it.
        case .silencesCancelled: return errorSessionOther.text
        case .silencesRead(let code): return errorSilencesRead.format(Int(code))
        case .silencesStale: return errorSilencesStale.text
        case .silencesFaults(let faults):
            let names = faults.keys.sorted().map { session?.files[$0]?.path ?? $0.rawValue }
            return errorSilencesFaults.format(names.joined(separator: ", "))
        case .segment(_, .session(let error)): return message(for: error, name: name)
        case .segment(let segment, let fault): return message(for: fault).format(segment.stem)
        case .artwork(let error): return message(for: error)
        case .unusedFiles(let error): return message(for: error)
        // Retry Finalize is the control that finishes the pending take, so the text names it.
        case .writerDidNotStop(let name): return errorWriterDidNotStop.format(name, menuRecordRetry.text)
        }
    }

    /// The text of a failed transcription job. The switch has no `default`.
    static func message(for error: TranscribeError) -> String {
        switch error {
        case .modelLoad: errorTranscribeLoad.text
        case .modelDownload: errorTranscribeDownload.text
        case .modelDownloadNoData(let host): errorTranscribeDownloadNoData.format(host)
        case .modelWrite(let folder, let code): errorTranscribeFolder.format(folder, Int(code))
        case .modelDownloadChecksum: errorTranscribeDownloadChecksum.text
        case .modelChecksum: errorTranscribeChecksum.text
        case .audioRead(let file, let code): errorTranscribeAudio.format(file, Int(code))
        // The app finds the VAD model in its bundle first, so either case means a damaged install.
        case .vadModelMissing, .vadModelChecksum: errorTranscribeVad.text
        case .engine(let code): errorTranscribeEngine.format(Int(code))
        case .modelFile(let error): message(for: error)
        case .modelChanged: errorTranscribeFileChanged.text
        case .languageNotInModel: errorTranscribeFileEnglish.text
        }
    }

    /// The text of a model file check that gave no checked model (decision 0065, D8). The switch
    /// has no `default`.
    static func message(for error: ModelFileCheckError, text: (L10n) -> String = { $0.text }) -> String {
        switch error {
        case .unreadable(let code): errorTranscribeFileUnreadable.format(Int(code))
        case .helperMissing: errorTranscribeFileHelperMissing.text
        // The error of `Process.run()` can name a false cause: a file with no execute permission
        // gives NSCocoaErrorDomain 4, "doesn't exist". The text gives only the domain and the code.
        case .helperNotStarted(_, let domain, let code): errorTranscribeFileHelperStart.format(domain, code)
        case .refused(let reason):
            String(format: text(.errorTranscribeFileRefused), locale: .current, Self.reason(reason, text: text))
        case .helperStopped(let signal): errorTranscribeFileCrashed.format(Int(signal))
        case .changedDuringCheck: errorTranscribeFileChanged.text
        // A stop ends the job with `.transcriptionCancelled` or `.transcriptionYielded`, not with this case.
        case .stopped: transcribeCanceled.text
        }
    }

    /// The reason in the alert of a report that was not written (decision 0059). The switch has
    /// no `default`, so a new case does not compile until it has a key.
    static func message(for error: BundleError) -> String {
        switch error {
        case .exists: reportErrorExists.text
        case .folderMissing: reportErrorFolder.text
        case .noPermission: reportErrorPermission.text
        case .tempFolder: reportErrorTemporary.text
        case .zipFailed(let code): reportErrorZip.format(code)
        }
    }

    /// The text of a refused Remove Unused Files (decision 0047): no file moved.
    private static func message(for error: UnusedFilesError) -> String {
        switch error {
        case .clipsUnreadable(let code): errorUnusedClips.format(Int(code))
        case .transcriptsUnreadable(let code): errorUnusedTranscripts.format(Int(code))
        case .sessionUnreadable(let error), .save(let error): message(for: error)
        case .backupUnreadable(let backup, _): errorUnusedBackup.format(backupTitle(backup.saved))
        case .changedDuringPrune: errorUnusedChanged.text
        }
    }

    /// The text of an artwork import error (decision 0045): it gives the found type or size.
    private static func message(for error: ArtworkError) -> String {
        switch error {
        case .notDownloaded(let file): errorArtworkNotDownloaded.format(file)
        case .unreadable(let file): errorArtworkUnreadable.format(file)
        case .notJPEGOrPNG(let type): errorArtworkType.format(UTType(type)?.localizedDescription ?? type)
        case .notSquare(let width, let height): errorArtworkSquare.format(width, height)
        case .tooLarge(let side): errorArtworkLarge.format(maximumArtworkSide, side)
        case .writeFailed(let code): errorArtworkWrite.format(Int(code))
        }
    }

    /// The text of a paste error (decision 0042, `ui-panel.md` item 2), with the name of the source
    /// session. The window shows no alert for a cancel.
    private static func message(for error: PasteError, source: String) -> String {
        switch error {
        case .sourceMissing: errorPasteMissing.format(source)
        case .sourceChanged: errorPasteChanged.format(source)
        case .notDownloaded(let file): errorImportNotDownloaded.format(file)
        case .space, .write(_, ENOSPC): errorPasteSpace.format(source)
        case .write(_, let code): errorPasteCopy.format(source, Int(code))
        case .convert(_, let code): errorPasteConvert.format(source, Int(code))
        case .cancelled, .session: errorSessionOther.text
        }
    }

    /// The text of a split error (decision 0053). The window shows no alert for a cancel, and a
    /// session refusal has the session text.
    private static func message(for error: SplitError) -> String {
        switch error {
        case .space, .write(_, ENOSPC): errorSplitSpace.text
        case .write(_, let code): errorSplitWrite.format(Int(code))
        case .sourceUnreadable(let file, let code): errorSplitUnreadable.format(file, Int(code))
        case .sourceMissing(let file): errorSplitMissing.format(file)
        case .cancelled, .session: errorSessionOther.text
        }
    }

    /// The text of a clip render error (decision 0054), as a split error.
    private static func message(for error: ClipRenderError) -> String {
        switch error {
        case .space, .write(_, ENOSPC): errorDenoiseSpace.text
        case .write(_, let code): errorDenoiseWrite.format(Int(code))
        case .sourceUnreadable(let file, let code): errorDenoiseUnreadable.format(file, Int(code))
        case .sourceMissing(let file): errorDenoiseMissing.format(file)
        case .notDownloaded(let file): errorDenoiseNotDownloaded.format(file)
        case .trackRole: errorDenoiseTrackRole.text
        case .mixedTreatments: errorDenoiseMixed.text
        case .effectUnavailable(let status): errorDenoiseUnavailable.format(Int(status))
        case .engine(let status): errorDenoiseEngine.format(Int(status))
        case .stillOverFullScale(let file): errorDenoiseOverFullScale.format(file)
        case .cornerTooHigh(let hertz, .hertz(let limit)): errorDenoiseCornerLimit.format(hertz, limit)
        case .cornerTooHigh(let hertz, .lowestRate(let rate)): errorDenoiseCornerRate.format(hertz, rate)
        case .nonFiniteSample(let file): errorDenoiseNonFinite.format(file)
        case .cancelled, .session: errorSessionOther.text
        }
    }

    /// The key of a placement refusal (decision 0021). A session refusal has the session text.
    private static func message(for fault: SegmentFault) -> L10n {
        switch fault {
        case .notUnplaced: errorSegmentNotUnplaced
        case .noSidecar: errorSegmentNoSidecar
        case .newerSidecar: errorSegmentNewer
        case .badAudio: errorSegmentBadAudio
        case .beforeTimeline: errorSegmentBeforeStart
        case .noAlignment: errorSegmentNoAlignment
        case .newerAnchor: errorSegmentNewerAnchor
        case .wavInUse: errorSegmentWAVInUse
        case .session: errorSessionOther
        }
    }

    /// The text of an export error. The window shows no alert for a cancel, so `.cancelled` has
    /// no key.
    private static func message(for error: ExportError) -> String {
        switch error {
        case .exists: errorExportExists.text
        case .chapterImageExists(let path):
            errorExportChapterImageExists.format(URL(filePath: path).lastPathComponent)
        case .rateNotSupported(let rate): errorExportRate.format(rate)
        case .diskFull: errorExportDiskFull.text
        case .writeFailed(let status): errorExportWrite.format(Int(status))
        case .moveFailed(let code): errorExportMove.format(Int(code))
        case .openFailed(let code): errorExportOpen.format(Int(code))
        case .packageUnavailable: errorExportPackage.text
        case .artworkMissing(let file): errorExportArtwork.format(file)
        case .chapterImageMissing(let chapter, let rate):
            errorExportChapterImage.format(chapter.name, timeDisplayText(chapter.position, rate: rate, playing: false))
        case .tooManyChapters(let count): errorExportChapters.format(count, maximumChapters)
        case .tagTooLarge: errorExportTag.text
        case .chaptersTooLong: errorExportChaptersTooLong.text
        case .cancelled: ""
        }
    }

    /// The text of a failed Export Transcript. The number from the panel names no transcript when
    /// an edit removed it while the panel showed.
    static func message(for error: TranscriptExportError) -> String {
        switch error {
        case .cues(.noTranscript), .cues(.severalTranscripts), .cues(.unknownTranscript): errorTranscriptGone.text
        case .cues(.notLoaded): errorTranscriptUnloaded.text
        case .cues(.noCue): errorTranscriptEmpty.text
        case .write(let error): message(for: error)
        }
    }

    /// The text of an import error (decision 0040): it quotes the file and says what to do. The
    /// window shows no alert for a cancel, so `.cancelled` has no key.
    private static func message(for error: ImportError) -> String {
        switch error {
        case .notAudio(let file): errorImportNotAudio.format(file)
        case .notDownloaded(let file): errorImportNotDownloaded.format(file)
        case .tooManyChannels(let file, let channels): errorImportChannels.format(file, channels)
        case .space(let file, let needed, let free): errorImportSpace.format(file, bytes(needed), bytes(free))
        case .unreadable(let file, let code): errorImportUnreadable.format(file, Int(code))
        case .write(let file, .writeFailed(_, let code)), .write(let file, .readFailed(_, let code)),
            .write(let file, .segmentUnreadable(_, _, let code)):
            errorImportWrite.format(file, Int(code))
        case .session(let error): message(for: error, name: { $0.rawValue })
        case .cancelled: ""
        }
    }

    /// The text of a stop of playback that the user did not ask for.
    static func message(for stop: PlaybackStop) -> String {
        switch stop {
        case .outputChanged: transportStopOutputChanged.text
        case .outputUnavailable(let code): transportStopOutputUnavailable.format(code)
        case .packageUnavailable: transportStopPackageUnavailable.text
        case .noFreeDescriptor(let code): transportStopNoDescriptor.format(code)
        }
    }

    private static func message(for error: SessionError, name: (TrackID) -> String) -> String {
        switch error {
        case .invalidText: return errorSessionName.text
        case .layoutMismatch(let track, _): return errorSessionLayout.format(name(track))
        case .trackInRecording(let track): return errorSessionTrackInTake.format(name(track))
        case .trackCount(let count): return errorSessionTrackCount.format(count)
        // The window never makes these edits: they are bugs, not user errors.
        case .duplicateID, .unknownCapture, .unknownFile, .unknownTrack, .unknownClip, .unknownMarker,
            .captureInUse, .invalidCapture, .fileInUse, .fileIsSource, .invalidOrigin, .invalidRoute, .invalidPath,
            .frameOutOfRange,
            .markerURLTooLong,
            .takeOutOfRange, .clipOutsideFile, .overlap, .frameOutsideClip, .pointOutsideClip, .fadeOutsideClip,
            .crossfadeOutsideFile,
            .crossfadeWithoutJoin, .crossfadeAtSeamlessJoin, .crossfadeAtEqualGains, .fadeAtCrossfade, .laneOutOfRange,
            .foreignFile,
            .otherSampleRate, .unknownWord, .noWordOnTrack, .noTakeAudio,
            .wordOutsideFile, .nothingToCut, .chapterOutOfRange, .chapterImageNotKept, .nothingToHeal, .notStereo:
            return errorSessionOther.text
        // A transcript cut, a split (0053), and a clip render (0054) refuse it while a transcript did not load.
        case .transcriptNotLoaded: return errorTranscriptUnloaded.text
        case .noSpeechTrack: return errorDuckNoSpeechTrack.text
        case .noDuckedTrack: return errorDuckNoDuckedTrack.text
        case .trackInBothDuckLists(let track): return errorDuckBothLists.format(name(track))
        case .noSpeech(_, let threshold, _): return errorDuckNoSpeech.format(threshold)
        case .duckRangePastEnd: return errorDuckPastEnd.text
        }
    }

    private static func message(for error: SessionFileError) -> String {
        switch error {
        case .unsupportedVersion: return errorFileNewer.text
        case .malformedXML, .invalidChannelCount, .missingAttribute, .invalidValue, .invalidSession:
            return errorFileUnreadable.text
        case .readFailed(let errno): return errorFileRead.format(Int(errno))
        case .writeFailed(_, let errno): return errorFileWrite.format(Int(errno))
        case .wouldNotReadBack: return errorFileInternal.text
        case .locked: return errorLocked.text
        case .packageMoved: return errorFileMoved.text
        case .exists: return errorFileExists.text
        }
    }
}
