import DirigibleAudio
import DirigibleCore
import Foundation

// The English text of each error line of the CLI, without "Error: ". An MCP tool gives the same
// text in its error result (decision 0041).

/// The refusal of an app route on a macOS with no process taps (A14).
package let appSourcesUnavailableMessage = "app sources need macOS 14.2 or later."

package func pendingTakeMessage(_ package: String) -> String {
    "\(package) has a take that is not finalized; open it in Dirigible first."
}

package func splitTakeMessage(_ package: String) -> String {
    "\(package) has a take with some segments on the timeline and some not. A ripple moves the timeline under the "
        + "other segments, so place them first (dirigible capture place)."
}

/// The refusal of a live agent call that copies files into a package that the app has open
/// (decision 0046).
func openInAppMessage(_ package: String) -> String {
    "\(package) is open in Dirigible. Do this in the app, or close the window."
}

/// The fault of the media check of `info` and `session_info`.
package func mediaCheckMessage(_ error: any Error) -> String {
    "cannot check the audio files: \(error.localizedDescription)"
}

extension EditFailure where Body == SessionError {
    package func message(package: String) -> String {
        switch self {
        case .file(let error): error.message(package: package)
        case .pendingTake: pendingTakeMessage(package)
        case .splitTake: splitTakeMessage(package)
        case .body(let error): error.message
        }
    }
}

extension EditFailure where Body == LevelFailure {
    package func message(package: String) -> String {
        switch self {
        case .file(let error): error.message(package: package)
        case .pendingTake: pendingTakeMessage(package)
        case .splitTake: splitTakeMessage(package)
        case .body(let error): error.message
        }
    }
}

extension EditFailure where Body == PasteError {
    package func message(package: String) -> String {
        switch self {
        case .file(let error): error.message(package: package)
        case .pendingTake: pendingTakeMessage(package)
        case .splitTake: splitTakeMessage(package)
        case .body(let error): error.message
        }
    }
}

extension EditFailure where Body == MarkerEditError {
    package func message(package: String) -> String {
        switch self {
        case .file(let error): error.message(package: package)
        case .pendingTake: pendingTakeMessage(package)
        case .splitTake: splitTakeMessage(package)
        case .body(let error): error.message
        }
    }
}

extension EditFailure where Body == ArtworkError {
    package func message(package: String) -> String {
        switch self {
        case .file(let error): error.message(package: package)
        case .pendingTake: pendingTakeMessage(package)
        case .splitTake: splitTakeMessage(package)
        case .body(let error): error.message
        }
    }
}

extension ArtworkError {
    /// No `default` case: a new error case does not compile until it has a message.
    package var message: String {
        switch self {
        case .notDownloaded(let file): "the artwork file \"\(file)\" is not on this Mac. Download it first."
        case .unreadable(let file): "the artwork file \"\(file)\" does not open as an image."
        case .notJPEGOrPNG(let type): "the artwork is \(type), not JPEG or PNG."
        case .notSquare(let width, let height): "the artwork is \(width) x \(height) pixels; it must be square."
        case .tooLarge(let side):
            "the artwork is \(side) x \(side) pixels; the largest is \(maximumArtworkSide) x \(maximumArtworkSide)."
        case .writeFailed(let code): "the copy of the artwork into Artwork/ failed: \(String(cString: strerror(code)))."
        }
    }
}

extension EditFailure where Body == UnusedFilesError {
    package func message(package: String) -> String {
        switch self {
        case .file(let error): error.message(package: package)
        case .pendingTake: pendingTakeMessage(package)
        case .splitTake: splitTakeMessage(package)
        case .body(let error): error.message(package: package)
        }
    }
}

extension EditFailure where Body == RevertError {
    package func message(package: String) -> String {
        switch self {
        case .file(let error): error.message(package: package)
        case .pendingTake: pendingTakeMessage(package)
        case .splitTake: splitTakeMessage(package)
        case .body(let error): error.message(package: package)
        }
    }
}

extension RevertError {
    /// Each file error names the file that failed: the backup, `session.xml`, or `Backups`.
    package func message(package: String) -> String {
        switch self {
        case .backup(let backup, let error):
            error.message(package: package, file: "\(backupsFolderName)/\(backup.fileName)")
        case .currentCopy(let error):
            error.message(
                package: package, file: { if case .readFailed = error { "session.xml" } else { backupsFolderName } }())
                + copyFirst
        case .session(let error): error.message
        }
    }
}

/// The end of the text of a failed copy before a revert.
private let copyFirst = " The revert keeps a backup of session.xml first, so session.xml did not change."

extension PasteError {
    /// No `default` case: a new error case does not compile until it has a message.
    package var message: String {
        switch self {
        case .sourceMissing(let file): "the source \"\(file)\" is not there: the source package moved or was deleted."
        case .notDownloaded(let file): "the source file \"\(file)\" is not on this Mac. Download it first."
        case .sourceChanged(let file): "the source file \"\(file)\" does not match its record in the source session."
        case .space(let needed, let free): "the paste needs \(needed) free bytes, and the disk has \(free)."
        case .write(let file, let code): "the copy of \"\(file)\" failed (errno \(code))."
        case .convert(let file, let code): "the conversion of \"\(file)\" failed (errno \(code))."
        case .cancelled: "the paste was cancelled."
        case .session(let error): error.message
        }
    }
}

extension SplitError {
    /// No `default` case: a new error case does not compile until it has a message.
    package var message: String {
        switch self {
        case .space(let needed, let free): "the split needs \(needed) free bytes, and the disk has \(free)."
        case .write(let file, let code): "the split cannot write \"\(file)\" (errno \(code))."
        case .sourceUnreadable(let file, let code): "the split cannot read the source \"\(file)\" (errno \(code))."
        case .sourceMissing(let file): "the split cannot find the source \"\(file)\" in Clips/."
        case .cancelled: "the split was cancelled."
        case .session(let error): error.message
        }
    }
}

extension TranscriptFileError {
    package var message: String {
        switch self {
        case .unreadable: "the file is not WebVTT, SRT, or Whisper JSON."
        case .noTimedWord: "no word has a usable time."
        }
    }
}

extension ChaptersFileError {
    package var message: String {
        switch self {
        case .notAnObject: "the file is not a JSON object."
        case .noChapters: "the file has no chapter: it needs a \"chapters\" array with one chapter or more."
        case .unsupportedVersion(let version):
            version.map { "version \"\($0)\" is not 1.x; Dirigible reads versions 1.x." }
                ?? "the file has no \"version\"; Dirigible reads versions 1.x."
        case .startTime(let place): "chapter \(place) has no startTime that is a number of seconds, 0 or more."
        case .title(let place): "the title of chapter \(place) has a control character."
        }
    }
}

extension SessionError {
    /// No `default` case: a new error case does not compile until it has a message.
    package var message: String {
        switch self {
        case .duplicateID(let id): "the ID \"\(id)\" is already used."
        case .unknownCapture(let id): "no capture \"\(id)\"."
        case .unknownFile(let id): "no file \"\(id)\"."
        case .unknownTrack(let id): "no track \"\(id)\"."
        case .unknownClip(let id): "no clip \"\(id)\"."
        case .unknownMarker(let id): "no marker \"\(id)\"."
        case .captureInUse(let id): "capture \"\(id)\" is used by a file."
        case .invalidCapture(let id):
            "capture \"\(id)\" has a sample time that is not finite or a rate that is not positive."
        case .fileInUse(let id): "file \"\(id)\" is used by a clip."
        case .fileIsSource(let id, let file): "file \"\(id)\" is the source of rendered file \"\(file)\"."
        case .invalidOrigin(let id): "file \"\(id)\" has an origin that names no matching source range."
        case .trackInRecording(let id): "track \"\(id)\" is armed in the recording."
        case .layoutMismatch(let track, .file(let file)):
            "file \"\(file)\" does not have the layout of track \"\(track)\"."
        case .layoutMismatch(let track, .route): "the route does not have the layout of track \"\(track)\"."
        case .layoutMismatch(let track, .trackHasClips): "track \"\(track)\" has clips, so its layout cannot change."
        case .invalidRoute: "the route has a channel number less than 1 or an empty app ID."
        case .invalidPath(let path): "the path \"\(path)\" is not inside Clips/."
        case .invalidText(let text): "the text \(String(reflecting: text)) has a control character."
        case .frameOutOfRange: "a frame is negative or more than 2^40."
        case .markerURLTooLong: Marker.urlTooLongText
        case .takeOutOfRange(let take): "take \(take) is not in 1...999999999."
        case .clipOutsideFile(let id): "clip \"\(id)\" is not inside its file."
        case .overlap(let clip, let other): "clip \"\(clip)\" overlaps clip \"\(other)\"."
        case .frameOutsideClip(let id, let frame): "frame \(frame) is not inside clip \"\(id)\"."
        case .pointOutsideClip(let id, let frame, let range):
            "frame \(frame) is not inside clip \"\(id)\", which plays the timeline frames "
                + "\(range.lowerBound)..<\(range.upperBound)."
        case .fadeOutsideClip(let id, let length):
            "the fades and crossfades of clip \"\(id)\" are longer than the clip (\(length) frames)."
        case .crossfadeOutsideFile(let id, let needed):
            "clip \"\(id)\" needs \(needed) frames of audio past its edge in its file for this crossfade."
        case .crossfadeWithoutJoin(let id): "no clip touches the crossfade edge of clip \"\(id)\"."
        case .crossfadeAtSeamlessJoin(let id):
            "session.xml is from an older version of Dirigible that cannot hold a crossfade between clip \"\(id)\" "
                + "and the next clip, which play one piece of audio. Remove crossfadeOut from that clip and crossfadeIn "
                + "from the next clip in session.xml."
        case .crossfadeAtEqualGains(let id):
            "clip \"\(id)\" and the next clip play one piece of audio at one gain at each frame, the envelope "
                + "included, with no fade at the join, so a crossfade there changes nothing."
        case .fadeAtCrossfade(let id):
            "clip \"\(id)\" has a crossfade at that edge, so it cannot also have a fade there."
        case .trackCount(let count): "the excerpt has \(count) tracks, so give \(count) different target tracks."
        case .laneOutOfRange(let id): "the lane offset moves clip \"\(id)\" past the first or the last track."
        case .otherSampleRate(let rate): "the excerpt is at \(rate) Hz, another rate than this session."
        case .foreignFile(let id): "file \"\(id)\" of the excerpt is another file in this session."
        case .unknownWord(let occurrence):
            "no word \(occurrence) on the timeline: it is not there now, or an edit changed it. Read the words again, "
                + "then cut."
        case .wordOutsideFile(let id): "a transcript word of file \"\(id)\" is not inside the file."
        case .nothingToCut: "the words have no audio to cut."
        case .noWordOnTrack(let id): "no word of the transcript is over a clip of track \"\(id)\"."
        case .noTakeAudio(let id, let take): "The track \(id) has no audio of take \(take) with a take time."
        case .transcriptNotLoaded(let ids):
            ids.count == 1
                ? "transcript \(ids[0]) did not load: its file is missing or damaged. Import the transcript again."
                : "transcripts \(ids.map(\.description).joined(separator: ", ")) did not load: their files are missing "
                    + "or damaged. Import the transcripts again."
        case .chapterOutOfRange(let place):
            "chapter \(place) starts at a frame that is negative or more than 2^40."
        case .chapterImageNotKept(let markers):
            "the import would drop the image of "
                + markers.map { "\"\($0.name)\" at \($0.position)" }.joined(separator: ", ")
                + ". The file has no chapter at the same time. Remove the chapter first, or add one at that time to "
                + "the file."
        case .nothingToHeal: "no join to heal."
        case .noSpeechTrack: "no speech track: give a track the dialogue role, or name the speech tracks."
        case .noDuckedTrack: "no track to duck: give a track the music role, or name the tracks to duck."
        case .trackInBothDuckLists(let id): "track \"\(id)\" is a speech track and a track to duck."
        case .noSpeech(let scope, let threshold, let unread):
            "no speech over \(String(format: "%.1f", threshold)) dBFS in the timeline frames "
                + "\(scope.lowerBound)..<\(scope.upperBound), so the duck changed nothing."
                + (unread.isEmpty
                    ? "" : " Speech files that did not read: \(unread.map(\.rawValue).joined(separator: ", ")).")
        case .duckRangePastEnd(let range, let end):
            "the range \(range.lowerBound)..<\(range.upperBound) starts at or after the session end at frame "
                + "\(end), so the duck changed nothing."
        case .notStereo(let id): "clip \"\(id)\" is on a mono track, so it has no two sides to split."
        }
    }
}

extension SessionFileError {
    /// No `default` case: a new error case does not compile until it has a message.
    package func message(package: String, file name: String = "session.xml") -> String {
        let file = "\(package)/\(name)"
        return switch self {
        case .malformedXML: "\(file) is not a Dirigible session file."
        case .unsupportedVersion(let version):
            "\(file) was made by a newer version of Dirigible (session version \(version)). This build reads version "
                + "\(sessionVersion) or lower."
        case .invalidChannelCount(let count): "\(file) has a file with \(count) channels."
        case .missingAttribute(let element, let attribute):
            "\(file) has a \(element) element with no \(attribute) attribute."
        case .invalidValue(let element, let attribute):
            "\(file) has a \(element) element with a bad \(attribute) value."
        case .invalidSession(let error): "\(file) breaks a session rule: \(error.message)"
        case .readFailed(let code): "cannot read \(file): \(String(cString: strerror(code)))."
        case .writeFailed(let step, let code): "cannot write \(file) (\(step)): \(String(cString: strerror(code)))."
        case .wouldNotReadBack: "the new session would not read back, so \(file) did not change. This is a bug."
        case .locked: "\(package) is open in Dirigible."
        case .packageMoved:
            "\(package) moved to another volume or was deleted, so \(package)/session.xml did not change."
        case .exists: "\(package) exists."
        }
    }
}

extension SegmentFault {
    /// No `default` case: a new fault does not compile until it has a message.
    package func message(segment: SegmentName) -> String {
        let capture = "\(captureFolderName)/\(segment.stem)"
        return switch self {
        case .notUnplaced:
            "\(segment) is on the timeline, is in a pending take, or has no audio in \(captureFolderName)/."
        case .noSidecar: "\(capture).sidecar is missing or damaged, so the timing of \(segment) is not known."
        case .newerSidecar(let version):
            "\(capture).sidecar was made by a newer version of Dirigible (version \(version)), so this build cannot "
                + "place \(segment)."
        case .badAudio: "\(capture).caf is not audio that Dirigible can convert."
        case .beforeTimeline: "\(segment) ends before the start of the timeline."
        case .noAlignment: "no take anchor gives the track and the start of \(segment). Give --track and --at."
        case .newerAnchor(let version):
            "\(captureFolderName)/take\(segment.take).anchor was made by a newer version of Dirigible (version "
                + "\(version)). Give --track and --at to place \(segment)."
        case .wavInUse(let file): "file \"\(file)\" has the path of Clips/\(segment.stem).wav."
        case .session(let error): error.message
        }
    }
}

extension StudioError {
    /// No `default` case: a new error case does not compile until it has a message.
    package func message(package: String) -> String {
        switch self {
        case .locked: SessionFileError.locked.message(package: package)
        case .busy: "\(package) is busy with a take."
        case .noRoute(let track): "track \"\(track)\" has no route."
        case .deviceMissing(let track): "the device of track \"\(track)\" is missing."
        case .channelOutOfRange(let track): "the device of track \"\(track)\" does not have its channel."
        case .channelInUse(let first, let second): "tracks \"\(first)\" and \"\(second)\" use the same channel."
        case .session(let error): error.message
        case .file(let error): error.message(package: package)
        case .finalize(.readFailed(let file, let code)), .finalize(.segmentUnreadable(_, let file, let code)):
            "cannot read \(package)/\(file): \(String(cString: strerror(code)))."
        case .finalize(.writeFailed(let file, let status)): "cannot write \(package)/\(file) (status \(status))."
        case .segment(let segment, let fault): fault.message(segment: segment)
        case .microphoneAccess:
            "the terminal has no microphone access. Allow it in System Settings > Privacy & Security > Microphone."
        case .diskLow: "the disk of \(package) has less than 1 GB free."
        case .appSourcesUnavailable: appSourcesUnavailableMessage
        case .placementSpace(let needed, let free):
            "the placement needs \(needed) bytes free on the disk of \(package); \(free) bytes are free."
        // No command exports through Studio; `dirigible export` calls `exportMix` (decision 0019).
        case .export(let error): "the export failed (\(error))."
        case .exportYielded: "a take in another studio stopped the export."
        // No command imports through Studio; `dirigible import` calls `importAudio` (decision 0040).
        case .audioImport(let error): "the import failed (\(error))."
        case .importYielded: "a take in another studio stopped the import."
        case .paste(let error, _): "the paste failed (\(error))."
        case .pasteYielded: "a take in another studio stopped the paste."
        case .split(let error): error.message
        case .splitYielded: "a take in another studio stopped the split."
        case .clipRender(let error): error.message
        case .clipRenderYielded: "a take in another studio stopped the noise reduction."
        case .rippleBlocked: "a ripple cannot move the timeline under a pending or split take."
        // No command sets the artwork through Studio; `episode set --artwork` calls `importArtwork`.
        case .artwork(let error): error.message
        // `file prune` calls `UnusedFiles` with no Studio.
        case .unusedFiles(let error): error.message(package: package)
        // No command levels through Studio; `dirigible level` calls `autoLevel`.
        case .levelCancelled: "the level was cancelled."
        case .duckCancelled: "the duck was cancelled."
        // No command reads through Studio; the read commands call `ReadWork.read`.
        case .readYielded: "a take stopped the read."
        case .readClosed: "the close of the window stopped the read."
        case .duckRead(let code): audioReadMessage(POSIXError(POSIXErrorCode(rawValue: code) ?? .EMFILE))
        case .writerDidNotStop(let name):
            "\(name) did not stop in time. The audio is safe in \(package)/Capture; open the package in "
                + "Dirigible to finish the take."
        }
    }
}

extension UnusedFilesError {
    /// No `default` case: a new error case does not compile until it has a message.
    package func message(package: String) -> String {
        switch self {
        case .clipsUnreadable(let code):
            "cannot read \(package)/\(clipsFolderName): \(String(cString: strerror(code)))."
        case .transcriptsUnreadable(let code):
            "cannot read \(package)/\(transcriptsFolderName): \(String(cString: strerror(code)))."
        case .sessionUnreadable(let error): error.message(package: package)
        case .backupUnreadable(let backup, let error):
            error.message(package: package, file: "\(backupsFolderName)/\(backup.fileName)")
                + " The scan cannot know the clips of that backup, so no file moves until that backup goes."
        case .save(let error): error.message(package: package) + " No file moved."
        case .changedDuringPrune: "an edit during the prune uses a listed file. No file moved."
        }
    }
}
