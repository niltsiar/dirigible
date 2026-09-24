import ArgumentParser
import DirigibleAudio
import DirigibleCore
import Foundation

struct TakeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "take", abstract: "Finalize a take that the app did not finalize.", subcommands: [Finalize.self])

    struct Finalize: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run the recovery of the app on a package, and list the audio that is not on the timeline.",
            discussion: "Exit 2 when the take stays pending, 3 when captured audio is not on the timeline.")
        @OptionGroup var package: PackageArgument

        func run() async throws {
            try await finalizeTake(url: package.url, path: package.path)
        }
    }
}

/// Opens the package with `Studio.open`, which runs the recovery of decision 0004. A take that
/// open left pending with no error (an earlier recovery died) gets one retry. Writes one warning
/// line for each unplaced segment (decision 0012).
@MainActor
private func finalizeTake(url: URL, path: String) async throws(ExitCode) {
    let studio: Studio
    do {
        studio = try await Studio.open(url)
    } catch {
        throw fail(error.message(package: path), code: packageError)
    }
    if studio.pendingTake != nil, studio.takeError == nil {
        try? await studio.retryFinalize()
    }
    if let error = studio.takeError {
        throw fail("\(error.message(package: path)) The take is still pending.", code: packageError)
    }
    guard !studio.unplacedSegments.isEmpty else { return }
    for stem in studio.unplacedSegments {
        FileHandle.standardError.write(Data("Warning: Capture/\(stem).caf is not on the timeline.\n".utf8))
    }
    throw ExitCode(unplacedAudio)
}

extension StudioError {
    /// No `default` case: a new error case does not compile until it has a message.
    func message(package: String) -> String {
        switch self {
        case .locked: SessionFileError.locked.message(package: package)
        case .session(let error): error.message
        case .file(let error): error.message(package: package)
        case .finalize(.readFailed(let file, let code)):
            "cannot read \(package)/\(file): \(String(cString: strerror(code)))."
        case .finalize(.writeFailed(let file, let status)): "cannot write \(package)/\(file) (status \(status))."
        }
    }
}
