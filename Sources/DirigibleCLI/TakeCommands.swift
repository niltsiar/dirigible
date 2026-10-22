import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

struct TakeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "take", abstract: "Finalize a take, or map take time to the timeline.",
        subcommands: [Finalize.self, Map.self])

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

    struct Map: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Give the timeline frames of take frames, or the take frames of timeline frames.",
            discussion:
                "Take frame 0 is the record start of the take. One line for each frame: the frame, then "
                + "<track>:<frame> for each clip that plays it, or cut when an edit removed it. With --timeline, "
                + "the frame, then <track>:<take frame> for each track with audio of the take there, or none. "
                + "Exit 64 for a timeline frame under 0, or with no --take when the session has two takes with audio or "
                + "more; exit 1 when the session or the take has no audio with a take time, or for an unknown "
                + "track; exit 2 when the package or a take anchor in Capture/ cannot be read.")
        @OptionGroup var package: PackageArgument
        @Argument(parsing: .allUnrecognized, help: "The frames.") var frames: [Int]
        @Option(help: "The take number. Give it when the session has two takes with audio or more.") var take: Int?
        @Flag(help: "Map timeline frames to take frames.") var timeline = false
        @Option(help: "A track to map. Repeat it for more tracks. The default is every track.")
        var track: [String] = []
        @Flag(help: "Write the map as JSON.") var json = false

        func validate() throws { _ = try query() }

        func query() throws(ValidationError) -> TakeMapQuery {
            do throws(ToolError) {
                return try TakeMapQuery(
                    frames: frames, take: take, timeline: timeline, tracks: track.map { TrackID($0) })
            } catch {
                throw ValidationError(error.message)
            }
        }

        func run() throws {
            let session = try readPackage(package)
            let (map, query) = (TakeMap.of(session, anchors: TakeAnchors.result(package.url)), try query())
            do throws(TakeMapError) {
                print(try TakeWork.text(map, session: session, query: query, json: json), terminator: "")
            } catch {
                switch error {
                case .anchor: throw fail(error.message, code: packageError)
                case .takeNeeded: throw fail(error.message, code: ExitCode.validationFailure.rawValue)
                case .noTakeAudio, .noSuchTake, .unknownTrack: throw fail(error.message, code: editRefused)
                }
            }
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
