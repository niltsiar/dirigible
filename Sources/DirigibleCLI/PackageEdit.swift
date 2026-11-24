import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
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

/// The `.cli` journal of a command that writes a line only at a fault (decision 0059): `log()`
/// starts it at the first call, so a run with no fault writes no file. `quit()` ends a started one.
final class FaultJournal {
    private var started: DiagnosticLog?

    func log() -> DiagnosticLog {
        if let started { return started }
        let log = DiagnosticLog.start(
            .cli, folder: DiagnosticLog.folder(), version: Dirigible.appVersion, commit: Dirigible.appCommit)
        started = log
        return log
    }

    func quit() { started?.quit() }
}

/// Runs `editPackageCore` and maps its failure: one error line on stderr and the exit code. A
/// session refusal exits 1, a package fault, a pending take, or a fault of the unarchive step exits
/// 2, and a split take on a
/// `ripple` edit exits 3 (decision 0037).
func editPackage<Result>(
    _ package: PackageArgument, ripple: RippleNeed, touchesClips: Bool, writeUnchanged: Bool = true,
    _ body: (inout Session) throws(SessionError) -> Result
) throws(ExitCode) -> Result {
    try editPackage(
        package, ripple: ripple, touchesClips: touchesClips, writeUnchanged: writeUnchanged, refused: refusedEdit
    ) {
        session, _ throws(SessionError) in
        try body(&session)
    }
}

/// The error line and the exit code of an edit that the session refuses.
private func refusedEdit(_ error: SessionError) -> ExitCode { fail(error.message, code: editRefused) }

/// `editPackage` for a body with its own error that also gets the lock: `refused` writes its line
/// and gives its exit code.
func editPackage<Result, Failure: Error>(
    _ package: PackageArgument, ripple: RippleNeed, touchesClips: Bool, writeUnchanged: Bool = true,
    refused: (Failure) -> ExitCode,
    _ body: (inout Session, PackageLock) throws(Failure) -> Result
) throws(ExitCode) -> Result {
    let journal = FaultJournal()
    defer { journal.quit() }
    do {
        return try editPackageCore(
            package.url, ripple: ripple, touchesClips: touchesClips, writeUnchanged: writeUnchanged, log: journal.log,
            body)
    } catch {
        throw editExit(error, package: package.path, refused: refused)
    }
}

/// The error line and the exit code of a package edit that changed nothing at `package`.
func editExit<Failure>(_ error: EditFailure<Failure>, package: String, refused: (Failure) -> ExitCode) -> ExitCode {
    switch error {
    case .body(let error): refused(error)
    case .file(let error): fail(error.message(package: package), code: packageError)
    case .pendingTake: fail(pendingTakeMessage(package), code: packageError)
    case .splitTake: fail(splitTakeMessage(package), code: unplacedAudio)
    case .archive(let fault): fail(fault.message(package: package), code: packageError)
    }
}

// Value parsers. Each one throws `ValidationError`, which swift-argument-parser turns into exit 64.

func parseLayout(_ text: String) throws -> ChannelLayout {
    guard let layout = ChannelLayout(rawValue: text) else { throw ValidationError("A layout is mono or stereo.") }
    return layout
}

/// `Gain(dB:)` refuses a value outside `Gain.range`, nan, and inf.
func parseGain(_ text: String) throws -> Gain {
    guard let dB = Double(text), let gain = Gain(dB: dB) else {
        throw ValidationError("A gain is a number of dB \(Gain.rangeText).")
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
