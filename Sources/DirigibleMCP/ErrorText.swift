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

extension RawVerdict {
    /// The reason of a `raw <stem> kept: <reason>` line of `info` and of a `rawKept` entry
    /// (decision 0071). A segment that passes the gate and still has its CAF is not removed yet.
    var keptReason: String {
        switch self {
        case .pendingTake: "pending take"
        case .notPlaced: "not placed"
        case .removable: "not removed yet"
        case .frames: "frames"
        case .rateChoice: "rate choice"
        case .alignment(let error): String(format: "alignment %.2f ms", error * 1000)
        case .saturated: "saturated WAV"
        case .archived: "archived as FLAC"
        }
    }
}

/// The fault of the media check of `info` and `session_info`.
package func mediaCheckMessage(_ error: any Error) -> String {
    "cannot check the audio files: \(error.localizedDescription)"
}

/// The body of an `EditFailure` with a text: a package edit gives one text for each failure, for
/// the CLI and for an MCP tool.
package protocol EditBodyText: Error {
    func message(package: String) -> String
}

extension EditFailure where Body: EditBodyText {
    package func message(package: String) -> String {
        switch self {
        case .file(let error): error.message(package: package)
        case .pendingTake: pendingTakeMessage(package)
        case .splitTake: splitTakeMessage(package)
        case .body(let error): error.message(package: package)
        }
    }
}

extension UnusedFilesError: EditBodyText {}
extension RevertError: EditBodyText {}
extension StudioError: EditBodyText {}

extension SessionError: EditBodyText {
    package func message(package _: String) -> String { message }
}

extension LevelFailure: EditBodyText {
    package func message(package _: String) -> String { message }
}

extension PasteError: EditBodyText {
    package func message(package _: String) -> String { message }
}

extension MarkerEditError: EditBodyText {
    package func message(package _: String) -> String { message }
}

extension ArtworkError: EditBodyText {
    package func message(package _: String) -> String { message }
}

extension TranscribeFailure: EditBodyText {
    package func message(package _: String) -> String { message }
}

extension TakeImportError: EditBodyText {
    package func message(package _: String) -> String { message }
}

extension DuckFailure: EditBodyText {
    package func message(package _: String) -> String { message }
}

extension SyncRefusal: EditBodyText {}

extension ClipRenderError: EditBodyText {
    package func message(package _: String) -> String { message }
}

extension SplitError: EditBodyText {
    package func message(package _: String) -> String { message }
}

extension BatchWork.Failure: EditBodyText {
    package func message(package: String) -> String { message(rippleBlocked: splitTakeMessage(package)) }
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
        case .sourceUnreadable(let package, let fault): fault.message(package: package)
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

extension SegmentFault {
    /// No `default` case: a new fault does not compile until it has a message.
    package func message(segment: SegmentName) -> String {
        let (caf, sidecar) = ("\(captureFolderName)/\(segment.cafName)", "\(captureFolderName)/\(segment.sidecarName)")
        return switch self {
        case .notUnplaced:
            "\(segment) is on the timeline, is in a pending take, or has no audio in \(captureFolderName)/."
        case .noSidecar: "\(sidecar) is missing or damaged, so the timing of \(segment) is not known."
        case .newerSidecar(let version):
            "\(sidecar) was made by a newer version of Dirigible (version \(version)), so this build cannot "
                + "place \(segment)."
        case .badAudio: "\(caf) is not audio that Dirigible can convert."
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
        // `liveExport` catches each `.exportParts` case first, and no command exports a set through Studio.
        case .exportParts(let error): "the export of the files failed (\(error))."
        case .exportPresets(.exists(let urls)): "an item is at \(urls.map(\.path).joined(separator: ", "))."
        case .exportPresets(.duplicateTargets(let urls)):
            "two presets give one file name: \(urls.map(\.path).joined(separator: ", "))."
        case .exportPresets(.rateNotSupported(let preset, let rate)):
            "preset \"\(preset.text)\" cannot write \(rate) Hz."
        case .exportPresets(.stopped(let stop)): "the preset export stopped (\(stop.error))."
        // `liveStems` catches each `.exportStems` case first, and no command exports stems through Studio.
        case .exportStems(let error): "the stem export failed (\(error))."
        case .template(let error): "the template copy failed (\(error))."
        case .templateYielded: "a take stopped the template copy."
        // No command imports through Studio; `dirigible import` calls `importAudio` (decision 0040).
        case .audioImport(let error): "the import failed (\(error))."
        case .importYielded: "a take in another studio stopped the import."
        case .paste(let error, _): "the paste failed (\(error))."
        case .sessionImport(let error, let source): error.message(source: source, package: package)
        case .sessionImportYielded: "a take in another studio stopped the session import."
        case .pasteYielded: "a take in another studio stopped the paste."
        case .split(let error): error.message
        case .splitYielded: "a take in another studio stopped the split."
        case .clipRender(let error): error.message
        case .clipRenderYielded: "a take in another studio stopped the clip render."
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
        case .transcription(let error): error.message
        case .transcriptionYielded: "a take stopped the transcription."
        case .transcriptionCancelled: "the transcription was cancelled."
        case .duckRead(let code): audioReadMessage(POSIXError(POSIXErrorCode(rawValue: code) ?? .EMFILE))
        case .rideCancelled: "the level over time was cancelled."
        case .rideRead(let code): audioReadMessage(POSIXError(POSIXErrorCode(rawValue: code) ?? .EMFILE))
        case .rideFault(let file, let fault): "file \(file) \(ExportText.describe(fault)); no ride changed."
        case .tooLittleVoice(.reference, let seconds):
            "the reference clip has \(seconds) s of voice; Match Voice needs \(Studio.matchVoiceSeconds) s."
        case .tooLittleVoice(.track(let track), let seconds):
            "track \(track) has \(seconds) s of voice; Match Voice needs \(Studio.matchVoiceSeconds) s."
        case .noTargetTrack:
            "Match Voice leaves out music and effects tracks and the track of the reference clip, so no track is "
                + "left to match."
        case .rangeOutsideReference(let clip):
            "the range must lie inside the reference clip, frames \(clip.lowerBound) to \(clip.upperBound)."
        case .matchCancelled: "the voice match was cancelled."
        case .matchRead(let code): audioReadMessage(POSIXError(POSIXErrorCode(rawValue: code) ?? .EMFILE))
        case .matchFault(let file, let fault): "file \(file) \(ExportText.describe(fault)); no track changed."
        case .syncNoMatch: "No match: the clip audio was not found on the track."
        case .syncFile(let file, let fault): "file \(file) \(ExportText.describe(fault)); no clip moved."
        case .syncRead(let code): audioReadMessage(POSIXError(POSIXErrorCode(rawValue: code) ?? .EMFILE))
        case .syncCancelled: "the sync was cancelled."
        // No command or tool scans through Studio; `silences` calls `ReadWork.read`.
        case .silencesCancelled: "the silence scan was cancelled."
        case .silencesRead(let code): audioReadMessage(POSIXError(POSIXErrorCode(rawValue: code) ?? .EMFILE))
        case .silencesStale: "the tracks changed after the silence scan; scan again."
        case .silencesFaults(let faults):
            faults.sorted { $0.key < $1.key }.map { "file \($0.key) \(ExportText.describe($0.value))" }
                .joined(separator: "; ") + "; its clips would read as silence, so the scan gives no silence."
        case .writerDidNotStop(let name):
            "\(name) did not stop in time. The audio is safe in \(package)/Capture; open the package in "
                + "Dirigible to finish the take."
        case .outputTermUnavailable: "the output latency of the playback device did not read; a pre-roll take needs it."
        case .preRollStopped(let stop): "the pre-roll play stopped because \(stop.reason), so the take did not start."
        case .favoritesLocked: "another process or a window has the Favorites store open."
        case .favoritesDamaged(let error): "the Favorites store does not read (\(error.map { "\($0)" } ?? "a take"))."
        case .favoritesFile(let error): "the Favorites store failed (\(error))."
        case .favoritesCopy(let error): "the copy into the Favorites store failed (\(error))."
        case .favoritesYielded: "a take in another studio stopped the add to Favorites."
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

extension TranscribeError {
    var message: String {
        switch self {
        case .modelLoad: "whisper.cpp did not load the model."
        case .engine(let code): "whisper.cpp failed with code \(code)."
        case .modelDownload: "the model download failed in the network or at the server."
        case .modelDownloadNoData(let host):
            "the model download got no byte from \(host) in the time limit. A firewall can block the download: "
                + "allow the connections to \(host) and to the hosts under hf.co."
        case .modelWrite(let folder, let code):
            "cannot write the model in \(folder): \(String(cString: strerror(code)))."
        case .modelDownloadChecksum:
            "the downloaded model does not have the size and the SHA-256 of the catalog, so it was deleted."
        case .modelChecksum: "the model file does not have the size and the SHA-256 of the catalog."
        case .audioRead(let file, let code):
            "\(file): \(audioReadMessage(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)))"
        case .vadModelMissing(let tried):
            "the VAD model is not at \(tried.joined(separator: ", ")). Transcription needs it to skip silence."
        case .vadModelChecksum(let file):
            "the VAD model at \(file) does not have the size and the SHA-256 that Dirigible pins. Transcription needs it to skip silence."
        case .modelFile(let error): error.message
        case .modelChanged: "the model file changed after its check."
        case .languageNotInModel: "the model file has only English: give the language en or auto."
        }
    }
}

extension ModelFileCheckError {
    /// No `default` case: a new error case does not compile until it has a message.
    package var message: String {
        switch self {
        case .unreadable(let code): "cannot read the model file: \(String(cString: strerror(code)))."
        case .helperMissing(let path): "the model check helper is not at \(path). Install Dirigible again."
        case .helperNotStarted(let path, let domain, let code):
            "the model check helper at \(path) did not start (\(domain) \(code)). Install Dirigible again."
        case .refused(let reason): "the model check refused the file: \(reason.message)"
        case .helperStopped(let signal): "the model file stopped the model check with signal \(signal)."
        case .changedDuringCheck: "the model file changed during its check."
        case .stopped: "the model check was stopped."
        }
    }
}
