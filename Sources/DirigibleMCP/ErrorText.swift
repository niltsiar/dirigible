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
        case .archive(let fault): fault.message(package: package)
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
