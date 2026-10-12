import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
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
        @Flag(help: "End the take without the audio of a segment that cannot be read. It stays in Capture/.")
        var leaveUnreadable = false

        func run() async throws {
            try await finalizeTake(url: package.url, path: package.path, leaveUnreadable: leaveUnreadable)
        }
    }
}

/// Opens the package with `Studio.open`, which runs the recovery of decision 0004. A take that
/// open left pending with no error (an earlier recovery died) gets one retry. Then the report of
/// `record` (decision 0013). After a crash no gap is known, so only an armed track with no clip
/// gives exit 5. With `leaveUnreadable`, a take that stays pending gets one retry that leaves the
/// unreadable segments unplaced (decision 0021).
@MainActor
private func finalizeTake(url: URL, path: String, leaveUnreadable: Bool) async throws(ExitCode) {
    let studio: Studio
    do {
        studio = try await Studio.open(url)
    } catch {
        throw fail(error.message(package: path), code: packageError)
    }
    let take = studio.pendingTake ?? studio.recoveredTake
    if studio.pendingTake != nil, studio.takeError == nil || leaveUnreadable {
        try? await studio.retryFinalize(leavingUnreadable: leaveUnreadable)
    }
    if let error = studio.takeError {
        var message = "\(error.message(package: path)) The take is still pending."
        if case .finalize(.segmentUnreadable) = error {
            message += " Run it again with --leave-unreadable to finish without that segment."
        }
        throw fail(message, code: packageError)
    }
    let code = reportTake(studio, take: take?.take, armed: take?.armedTracks ?? [], result: nil)
    if code != 0 { throw ExitCode(code) }
}
