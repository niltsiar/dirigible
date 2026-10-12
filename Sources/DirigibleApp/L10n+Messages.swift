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
        // The window beeps for it and shows no alert.
        case .rippleBlocked: return errorSessionOther.text
        case .segment(_, .session(let error)): return message(for: error, name: name)
        case .segment(let segment, let fault): return message(for: fault).format(segment.stem)
        case .artwork(let error): return message(for: error)
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
            .captureInUse, .invalidCapture, .fileInUse, .invalidRoute, .invalidPath, .frameOutOfRange,
            .markerURLTooLong,
            .takeOutOfRange, .clipOutsideFile, .overlap, .frameOutsideClip, .fadeOutsideClip, .crossfadeOutsideFile,
            .crossfadeWithoutJoin, .crossfadeAtSeamlessJoin, .fadeAtCrossfade, .laneOutOfRange, .foreignFile,
            .otherSampleRate:
            return errorSessionOther.text
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
