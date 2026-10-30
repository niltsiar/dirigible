import DirigibleAudio
import DirigibleCore
import Foundation
import UniformTypeIdentifiers

/// The texts of library errors and reports.
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
        case .duckRead(let code): return errorDuckRead.format(Int(code))
        case .segment(_, .session(let error)): return message(for: error, name: name)
        case .segment(let segment, let fault): return message(for: fault).format(segment.stem)
        case .artwork(let error): return message(for: error)
        case .unusedFiles(let error): return message(for: error)
        // Retry Finalize is the control that finishes the pending take, so the text names it.
        case .writerDidNotStop(let name): return errorWriterDidNotStop.format(name, menuRecordRetry.text)
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

    /// The loudness report of an export with a target (decision 0032): the output loudness, the
    /// true peak, and the gain.
    static func message(for report: LoudnessReport) -> String {
        [
            report.output.map { reportLoudness.format($0.value) } ?? reportLoudnessNone.text,
            report.truePeak.map { reportPeak.format($0) } ?? reportPeakNone.text,
            reportGain.format(report.gain.dB),
        ].joined(separator: ", ")
    }

    /// The sentence after the report of a gain over the auto-level limit. Empty for a usual gain.
    static func largeGainHint(for report: LoudnessReport) -> String {
        report.exceedsLevelLimit ? " " + reportGainLarge.text : ""
    }

    /// The banner text of an Auto Level: the head, the track volume sentence when no clip changed,
    /// then the count of clips at the limit and of clips with no level. `text` gives the value of
    /// a key, so a test can read the English table.
    static func message(for report: LevelReport, text: (L10n) -> String = { $0.text }) -> String {
        func count(_ key: L10n, _ value: Int) -> String { String(format: text(key), locale: .current, value) }
        var parts = [report.isEmpty ? text(.bannerLevelNone) : count(.bannerLevelChanged, report.changed)]
        if report.changed == 0 { parts.append(text(.bannerLevelVolume)) }
        if report.atLimit > 0 { parts.append(count(.bannerLevelLimit, report.atLimit)) }
        if report.unmeasured > 0 { parts.append(count(.bannerLevelUnmeasured, report.unmeasured)) }
        return parts.joined(separator: " ")
    }

    /// The result banner of a Reduce Noise run: "Reduced noise in 3 clips by 12 dB.", with one form for
    /// a single clip, and the forms with hum. A treatment with no noise reduction is hum alone. `text`
    /// gives the value of a key, so a test can read a table.
    static func denoiseResult(
        clips: Int, treatment: Treatment, text: (L10n) -> String = { $0.text }
    ) -> String {
        func fill(_ key: L10n, _ values: Int...) -> String {
            String(format: text(key), locale: .current, arguments: values)
        }
        let one = clips == 1
        switch (treatment.noise?.decibels, treatment.hum != nil) {
        case (nil, _): return one ? fill(.denoiseHumOne) : fill(.denoiseHumMany, clips)
        case (let decibels?, true):
            return one ? fill(.denoiseBothOne, decibels) : fill(.denoiseBothMany, clips, decibels)
        case (let decibels?, false):
            return one ? fill(.denoiseDoneOne, decibels) : fill(.denoiseDoneMany, clips, decibels)
        }
    }

    /// The result banner of a Repair Sound run (decision 0064 D4): "Repaired clipped peaks in 2 clips.
    /// The level is up to 4 dB lower." for a de-clip that found runs, "No clipped peaks found." for
    /// a de-clip alone that found none, and "Repaired the sound of 3 clips." for the other repairs.
    /// The drop sentence has no dB value of 0. `text` gives the value of a key.
    static func repairResult(_ result: RepairResult, text: (L10n) -> String = { $0.text }) -> String {
        func fill(_ key: L10n, _ values: Int...) -> String {
            String(format: text(key), locale: .current, arguments: values)
        }
        guard result.clips > 0 else { return text(.denoiseUnchanged) }
        guard result.declip, result.repaired > 0 else {
            if result.declip, !result.others { return text(.repairNone) }
            return result.clips == 1 ? fill(.repairSoundOne) : fill(.repairSoundMany, result.clips)
        }
        let one = result.repaired == 1
        let found = one ? fill(.repairPeaksOne) : fill(.repairPeaksMany, result.repaired)
        guard result.drop > 0 else { return found }
        return found + " " + (one ? fill(.repairDropOne, result.drop) : fill(.repairDropMany, result.drop))
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
