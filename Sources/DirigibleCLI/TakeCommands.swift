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

extension SegmentFault {
    /// No `default` case: a new fault does not compile until it has a message.
    func message(segment: SegmentName) -> String {
        let capture = "\(captureFolderName)/\(segment.stem)"
        return switch self {
        case .notUnplaced:
            "\(segment) is on the timeline, is in a pending take, or has no audio in \(captureFolderName)/."
        case .noSidecar: "\(capture).sidecar is missing or damaged, so the timing of \(segment) is not known."
        case .badAudio: "\(capture).caf is not audio that Dirigible can convert."
        case .beforeTimeline: "\(segment) ends before the start of the timeline."
        case .noAlignment: "no take anchor gives the track and the start of \(segment). Give --track and --at."
        case .wavInUse(let file): "file \"\(file)\" has the path of Clips/\(segment.stem).wav."
        case .session(let error): error.message
        }
    }
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
        case .finalize(.readFailed(let file, let code)), .finalize(.segmentUnreadable(_, let file, let code)):
            "cannot read \(package)/\(file): \(String(cString: strerror(code)))."
        case .finalize(.writeFailed(let file, let status)): "cannot write \(package)/\(file) (status \(status))."
        case .segment(let segment, let fault): fault.message(segment: segment)
        case .microphoneAccess:
            "the terminal has no microphone access. Allow it in System Settings > Privacy & Security > Microphone."
        case .diskLow: "the disk of \(package) has less than 1 GB free."
        case .placementSpace(let needed, let free):
            "the placement needs \(needed) bytes free on the disk of \(package); \(free) bytes are free."
        // No command exports through Studio; `dirigible export` calls `exportMix` (decision 0019).
        case .export(let error): "the export failed (\(error))."
        case .exportYielded: "a take in another studio stopped the export."
        }
    }
}
