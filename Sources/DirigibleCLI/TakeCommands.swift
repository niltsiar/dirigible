import ArgumentParser
import DirigibleAudio
import DirigibleCore
import Foundation

struct TakeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "take", abstract: "Finalize a take that the app did not finalize.", subcommands: [Finalize.self])

    struct Finalize: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Run the recovery of the app on a package, write the ID of each clip of the take, and list the audio "
                + "that is not on the timeline.",
            discussion:
                "Exit 2 when the take stays pending, 3 when captured audio is not on the timeline, 5 when an armed "
                + "track has no clip of the take.")
        @OptionGroup var package: PackageArgument

        func run() async throws {
            try await finalizeTake(url: package.url, path: package.path)
        }
    }
}

/// Opens the package with `Studio.open`, which runs the recovery of decision 0004. A take that
/// open left pending with no error (an earlier recovery died) gets one retry. Then the report of
/// `record` (decision 0013). After a crash no gap is known, so only an armed track with no clip
/// gives exit 5.
@MainActor
private func finalizeTake(url: URL, path: String) async throws(ExitCode) {
    let studio: Studio
    do {
        studio = try await Studio.open(url)
    } catch {
        throw fail(error.message(package: path), code: packageError)
    }
    let take = studio.pendingTake ?? studio.recoveredTake
    if studio.pendingTake != nil, studio.takeError == nil {
        try? await studio.retryFinalize()
    }
    if let error = studio.takeError {
        throw fail("\(error.message(package: path)) The take is still pending.", code: packageError)
    }
    let code = reportTake(studio, take: take?.take, armed: take?.armedTracks ?? [], result: nil)
    if code != 0 { throw ExitCode(code) }
}

extension StudioError {
    /// No `default` case: a new error case does not compile until it has a message.
    func message(package: String) -> String {
        switch self {
        case .locked: SessionFileError.locked.message(package: package)
        case .busy: "\(package) is busy with a take."
        case .noRoute(let track): "track \"\(track)\" has no route."
        case .deviceMissing(let track): "the device of track \"\(track)\" is missing."
        case .channelOutOfRange(let track): "the device of track \"\(track)\" does not have its channel."
        case .channelInUse(let first, let second): "tracks \"\(first)\" and \"\(second)\" use the same channel."
        case .session(let error): error.message
        case .file(let error): error.message(package: package)
        case .finalize(.readFailed(let file, let code)):
            "cannot read \(package)/\(file): \(String(cString: strerror(code)))."
        case .finalize(.writeFailed(let file, let status)): "cannot write \(package)/\(file) (status \(status))."
        case .microphoneAccess:
            "the terminal has no microphone access. Allow it in System Settings > Privacy & Security > Microphone."
        case .diskLow: "the disk of \(package) has less than 1 GB free."
        }
    }
}
