import DirigibleAudio
import DirigibleCore
import Foundation

// The English text of each error line of the CLI, without "Error: ". An MCP tool gives the same
// text in its error result (decision 0041).

/// The refusal of an app route on a macOS with no process taps (A14).
let appSourcesUnavailableMessage = "app sources need macOS 14.2 or later."

func pendingTakeMessage(_ package: String) -> String {
    "\(package) has a take that is not finalized; open it in Dirigible first."
}

func splitTakeMessage(_ package: String) -> String {
    "\(package) has a take with some segments on the timeline and some not. A ripple moves the timeline under the "
        + "other segments, so place them first (dirigible capture place)."
}

/// The fault of the media check of `info` and `session_info`.
func mediaCheckMessage(_ error: any Error) -> String { "cannot check the audio files: \(error.localizedDescription)" }

extension EditFailure where Body == SessionError {
    func message(package: String) -> String {
        switch self {
        case .file(let error): error.message(package: package)
        case .pendingTake: pendingTakeMessage(package)
        case .splitTake: splitTakeMessage(package)
        case .body(let error): error.message
        }
    }
}

extension EditFailure where Body == PasteError {
    func message(package: String) -> String {
        switch self {
        case .file(let error): error.message(package: package)
        case .pendingTake: pendingTakeMessage(package)
        case .splitTake: splitTakeMessage(package)
        case .body(let error): error.message
        }
    }
}

extension PasteError {
    /// No `default` case: a new error case does not compile until it has a message.
    var message: String {
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

extension SessionError {
    /// No `default` case: a new error case does not compile until it has a message.
    var message: String {
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
        case .trackInRecording(let id): "track \"\(id)\" is armed in the recording."
        case .layoutMismatch(let track, .file(let file)):
            "file \"\(file)\" does not have the layout of track \"\(track)\"."
        case .layoutMismatch(let track, .route): "the route does not have the layout of track \"\(track)\"."
        case .layoutMismatch(let track, .trackHasClips): "track \"\(track)\" has clips, so its layout cannot change."
        case .invalidRoute: "the route has a channel number less than 1 or an empty app ID."
        case .invalidPath(let path): "the path \"\(path)\" is not inside Clips/."
        case .invalidText(let text): "the text \(String(reflecting: text)) has a control character."
        case .frameOutOfRange: "a frame is negative or more than 2^40."
        case .takeOutOfRange(let take): "take \(take) is not in 1...999999999."
        case .clipOutsideFile(let id): "clip \"\(id)\" is not inside its file."
        case .overlap(let clip, let other): "clip \"\(clip)\" overlaps clip \"\(other)\"."
        case .frameOutsideClip(let id, let frame): "frame \(frame) is not inside clip \"\(id)\"."
        case .fadeOutsideClip(let id, let length):
            "the fades and crossfades of clip \"\(id)\" are longer than the clip (\(length) frames)."
        case .crossfadeOutsideFile(let id, let needed):
            "clip \"\(id)\" needs \(needed) frames of audio past its edge in its file for this crossfade."
        case .crossfadeWithoutJoin(let id): "no clip touches the crossfade edge of clip \"\(id)\"."
        case .crossfadeAtSeamlessJoin(let id):
            "clip \"\(id)\" and the next clip play one piece of audio; a crossfade there would be 3 dB too loud."
        case .fadeAtCrossfade(let id):
            "clip \"\(id)\" has a crossfade at that edge, so it cannot also have a fade there."
        case .trackCount(let count): "the excerpt has \(count) tracks, so give \(count) different target tracks."
        case .laneOutOfRange(let id): "the lane offset moves clip \"\(id)\" past the first or the last track."
        case .foreignFile(let id): "file \"\(id)\" of the excerpt is another file in this session."
        }
    }
}

extension SessionFileError {
    /// No `default` case: a new error case does not compile until it has a message.
    func message(package: String) -> String {
        let file = "\(package)/session.xml"
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
        case .packageMoved: "\(package) moved to another volume or was deleted, so \(file) did not change."
        case .exists: "\(package) exists."
        }
    }
}
