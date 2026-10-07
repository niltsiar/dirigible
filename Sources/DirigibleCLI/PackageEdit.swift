import ArgumentParser
import DirigibleCore
import Foundation

/// The exit code for an edit that the session refuses (decision 0011).
let editRefused: Int32 = 1
/// The exit code for a package that cannot be read, written, or made, is locked, or keeps a
/// pending take (decisions 0011 and 0012).
let packageError: Int32 = 2
/// The exit code for captured audio that is not on the timeline (`take finalize`, decision 0012),
/// and for a ripple with a split take (decision 0037).
let unplacedAudio: Int32 = 3

/// Writes one line `Error: <message>` to stderr and returns the exit code to throw.
func fail(_ message: String, code: Int32) -> ExitCode {
    // The throwing write: a closed stderr gives an error here, not an exception that aborts.
    try? FileHandle.standardError.write(contentsOf: Data("Error: \(message)\n".utf8))
    return ExitCode(code)
}

func readPackage(_ package: PackageArgument) throws(ExitCode) -> Session {
    do {
        return try Session(contentsOf: package.url)
    } catch {
        throw fail(error.message(package: package.path), code: packageError)
    }
}

/// Runs `editPackageCore` and maps its failure: one error line on stderr and the exit code. A
/// session refusal exits 1, a package fault or a pending take exits 2, and a split take on a
/// `ripple` edit exits 3 (decision 0037).
func editPackage<Result>(
    _ package: PackageArgument, ripple: Bool = false, _ body: (inout Session) throws(SessionError) -> Result
) throws(ExitCode) -> Result {
    try editPackage(package, ripple: ripple, refused: refusedEdit) { session, _ throws(SessionError) in
        try body(&session)
    }
}

/// The error line and the exit code of an edit that the session refuses.
private func refusedEdit(_ error: SessionError) -> ExitCode { fail(error.message, code: editRefused) }

/// `editPackage` for a body with its own error that also gets the lock: `refused` writes its line
/// and gives its exit code.
func editPackage<Result, Failure: Error>(
    _ package: PackageArgument, ripple: Bool = false, refused: (Failure) -> ExitCode,
    _ body: (inout Session, PackageLock) throws(Failure) -> Result
) throws(ExitCode) -> Result {
    do {
        return try editPackageCore(package.url, ripple: ripple, body)
    } catch {
        switch error {
        case .body(let error): throw refused(error)
        case .file(let error): throw fail(error.message(package: package.path), code: packageError)
        case .pendingTake: throw fail(pendingTakeMessage(package.path), code: packageError)
        case .splitTake: throw fail(splitTakeMessage(package.path), code: unplacedAudio)
        }
    }
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
    guard !numbers.contains(nil), let channels = EditRules.channels(numbers.compactMap { $0 }) else {
        throw ValidationError("Channels are one number or two numbers with a comma, for example 1,2.")
    }
    return channels
}
