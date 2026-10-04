import ArgumentParser
import DirigibleCore
import Foundation

/// The exit code for an edit that the session refuses (decision 0011).
let editRefused: Int32 = 1
/// The exit code for a package that cannot be read, written, or made, is locked, or keeps a
/// pending take (decisions 0011 and 0012).
let packageError: Int32 = 2
/// The exit code for captured audio that is not on the timeline (`take finalize`, decision 0012).
let unplacedAudio: Int32 = 3

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

/// Takes the package lock (decision 0012), reads the package, removes the leftover temporary
/// files of a crashed save (after the read, so a newer package does not change: decision 0024
/// P4), refuses one whose `session.xml` holds `<recording>` (decision 0004), applies `body`, and
/// saves. The lock is held until the save ends. The package does not change when the lock, the
/// read, the refusal, the edit, or the save fails. Writes one error line to stderr and throws the
/// exit code.
func editPackage<Result>(
    _ package: PackageArgument, _ body: (inout Session) throws(SessionError) -> Result
) throws(ExitCode) -> Result {
    let locked = { (error: SessionFileError) in fail(error.message(package: package.path), code: packageError) }
    return try PackageLock.withLock(package.url, locked: locked) { lock throws(ExitCode) -> Result in
        try editLocked(package, lock, body)
    }
}

private func editLocked<Result>(
    _ package: PackageArgument, _ lock: PackageLock, _ body: (inout Session) throws(SessionError) -> Result
) throws(ExitCode) -> Result {
    var session = try readPackage(package)
    Session.removeTemporaryFiles(in: package.url)
    guard session.recording == nil else {
        throw fail(
            "\(package.path) has a take that is not finalized; open it in Dirigible first.", code: packageError)
    }
    let result: Result
    do {
        result = try body(&session)
    } catch {
        throw fail(error.message, code: editRefused)
    }
    do {
        // The package that the lock holds, also after a rename (decision 0014).
        try session.write(under: lock)
    } catch {
        throw fail(error.message(package: package.path), code: packageError)
    }
    return result
}

// Value parsers. Each one throws `ValidationError`, which swift-argument-parser turns into exit 64.

func parseLayout(_ text: String) throws -> ChannelLayout {
    guard let layout = ChannelLayout(rawValue: text) else { throw ValidationError("A layout is mono or stereo.") }
    return layout
}

/// `Gain(dB:)` refuses nan and inf.
func parseGain(_ text: String) throws -> Gain {
    guard let dB = Double(text), let gain = Gain(dB: dB) else {
        throw ValidationError("A gain is a finite number of dB.")
    }
    return gain
}

/// "1" or "1,2". `Session` checks that each channel is 1 or more.
func parseChannels(_ text: String) throws -> Route.Channels {
    let numbers = text.split(separator: ",", omittingEmptySubsequences: false).map { Int($0) }
    switch (numbers.first ?? nil, numbers.last ?? nil, numbers.count) {
    case (let channel?, _, 1): return .mono(channel)
    case (let left?, let right?, 2): return .stereo(left, right)
    default: throw ValidationError("Channels are one number or two numbers with a comma, for example 1,2.")
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
