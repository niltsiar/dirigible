import ArgumentParser
import DirigibleCore
import Foundation

/// The exit code for a package that cannot be read, written, or made (decision 0011).
let packageError: Int32 = 2

/// Writes one line `Error: <message>` to stderr and returns the exit code to throw.
func fail(_ message: String, code: Int32) -> ExitCode {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    return ExitCode(code)
}

func readPackage(_ package: PackageArgument) throws(ExitCode) -> Session {
    do {
        return try Session(contentsOf: package.url)
    } catch {
        throw fail(error.message(package: package.path), code: packageError)
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
        case .invalidRoute: "a channel number is less than 1."
        case .invalidPath(let path): "the path \"\(path)\" is not inside Clips/."
        case .invalidText(let text): "the text \(String(reflecting: text)) has a control character."
        case .frameOutOfRange: "a frame is negative or more than 2^40."
        case .clipOutsideFile(let id): "clip \"\(id)\" is not inside its file."
        case .overlap(let clip, let other): "clip \"\(clip)\" overlaps clip \"\(other)\"."
        case .frameOutsideClip(let id, let frame): "frame \(frame) is not inside clip \"\(id)\"."
        }
    }
}

extension SessionFileError {
    /// No `default` case: a new error case does not compile until it has a message.
    func message(package: String) -> String {
        let file = "\(package)/session.xml"
        return switch self {
        case .malformedXML: "\(file) is not a Dirigible session file."
        case .unsupportedVersion(let version): "\(file) has version \(version). This build reads version 1 or lower."
        case .invalidChannelCount(let count): "\(file) has a file with \(count) channels."
        case .missingAttribute(let element, let attribute):
            "\(file) has a \(element) element with no \(attribute) attribute."
        case .invalidValue(let element, let attribute):
            "\(file) has a \(element) element with a bad \(attribute) value."
        case .invalidSession(let error): "\(file) breaks a session rule: \(error.message)"
        case .readFailed(let code): "cannot read \(file): \(String(cString: strerror(code)))."
        case .writeFailed(let step, let code): "cannot write \(file) (\(step)): \(String(cString: strerror(code)))."
        case .wouldNotReadBack: "the new session would not read back, so \(file) did not change. This is a bug."
        }
    }
}
