import AVFoundation
import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the input devices.",
        discussion:
            "One line for each device: the UID, the name, the input channels, and the nominal rate, split by tabs.")

    func run() { print(deviceLines(InputDevice.all()), terminator: "") }
}

/// The exit code for a take that stopped early because the disk is almost full (decision 0013).
let diskLowStop: Int32 = 4
/// The exit code for an armed track with a gap or with no clip of the take (decision 0013).
let trackGap: Int32 = 5

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record a take from the routed input devices, and write the ID of each clip.",
        discussion: """
            Exit 1 when the take did not start, 2 when the take stays pending, 3 when captured audio is not on \
            the timeline, 4 when the take stopped early because the disk is almost full, 5 when an armed track \
            has a gap or no clip of the take. Ctrl-C ends the process; `dirigible take finalize` recovers the take.
            """)
    @OptionGroup var package: PackageArgument
    @Option(parsing: .unconditional, help: "The length of the take in seconds, 86400 (24 h) or less.")
    var seconds: Double
    @Option(help: "An armed track. Repeat it for each track.") var arm: [String] = []
    @Option(parsing: .unconditional, help: "The timeline frame of the take start.") var playhead = 0

    func validate() throws {
        guard EditRules.takeSeconds(seconds) != nil else {
            throw ValidationError("The seconds must be more than 0 and 86400 (24 h) or less.")
        }
        guard !arm.isEmpty else { throw ValidationError("Arm one track or more with --arm.") }
        guard playhead >= 0 else { throw ValidationError("The playhead must be 0 or more.") }
    }

    /// The one command that runs the capture code, so the one command with a journal (decision 0059).
    func run() async throws {
        let log = DiagnosticLog.start(
            .cli, folder: DiagnosticLog.folder(), version: Dirigible.appVersion, commit: Dirigible.appCommit)
        defer { log.quit() }
        try await recordTake(
            package, armed: arm.map { TrackID($0) }, playhead: Frames(playhead), duration: .seconds(seconds), log: log)
    }
}

extension CaptureCommand {
    struct Place: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Place one segment that is not on the timeline, and write its clip ID.",
            discussion: """
                The default is the track of its arm at its recorded time, from the take anchor that the end of the \
                take wrote (decision 0021). Exit 1 when the segment is refused, 2 when the package cannot be read \
                or written, is locked, or has a take that is not finalized.
                """)
        @OptionGroup var package: PackageArgument
        @Argument(help: "The segment, for example take3-1-2.", transform: parseSegment) var segment: SegmentName
        @Option(help: "The track. The default is the track of the arm in the take anchor.") var track: String?
        @Option(
            parsing: .unconditional, help: "The timeline frame of the clip start. The default is the recorded time.")
        var at: Int?

        func validate() throws {
            if let at, at < 0 { throw ValidationError("The start must be 0 or more.") }
        }

        func run() async throws {
            try await placeSegment(package, segment, track: track.map { TrackID($0) }, start: at.map { Frames($0) })
        }
    }
}

func parseSegment(_ text: String) throws -> SegmentName {
    guard let segment = SegmentName(stem: text) else {
        throw ValidationError("A segment is take<n>-<arm>-<segment>, for example take3-1-2.")
    }
    return segment
}

/// Refuses a pending take before `Studio.open`, whose recovery would finalize it, then opens the
/// package.
@MainActor
private func openStudio(_ package: PackageArgument, log: DiagnosticLog = .disabled) async throws(ExitCode) -> Studio {
    guard try readPackage(package).recording == nil else {
        throw fail("\(package.path) has a take that is not finalized; open it in Dirigible first.", code: packageError)
    }
    do {
        return try await Studio.open(package.url, log: log)
    } catch {
        throw fail(error.message(package: package.path), code: packageError)
    }
}

@MainActor
private func placeSegment(
    _ package: PackageArgument, _ segment: SegmentName, track: TrackID?, start: Frames?
) async throws(ExitCode) {
    let studio = try await openStudio(package)
    do {
        print(try await studio.place(segment, on: track, at: start))
    } catch {
        throw fail(error.message(package: package.path), code: refusedCode(error))
    }
}

/// Requests the microphone access once when the status is not determined, and starts again
/// (decision 0013).
@MainActor
private func recordTake(
    _ package: PackageArgument, armed: [TrackID], playhead: Frames, duration: Duration, log: DiagnosticLog
) async throws(ExitCode) {
    let studio = try await openStudio(package, log: log)
    // A shell command records with no sheet: name each app it records (decision 0050, C18).
    for id in armed {
        guard let track = studio.session.track(id), case .app(let bundleID) = track.route else { continue }
        warn("Track \(track.name) records \(bundleID). People in the call get no notice from Dirigible.")
    }
    let result: TakeResult
    do throws(StudioError) {
        do throws(StudioError) {
            result = try await studio.record(armed: armed, playhead: playhead, for: duration)
        } catch {
            guard error == .microphoneAccess(.notDetermined) else { throw error }
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw .microphoneAccess(.denied) }
            result = try await studio.record(armed: armed, playhead: playhead, for: duration)
        }
    } catch {
        guard let take = studio.lastTake else {
            throw fail(error.message(package: package.path), code: refusedCode(error))
        }
        writeGaps(take.gaps, armed: armed)
        throw fail("\(error.message(package: package.path)) The take is still pending.", code: packageError)
    }
    let code = reportTake(studio, take: result.take, armed: armed, result: result)
    if code != 0 { throw ExitCode(code) }
}

/// Exit 1 for a take start or a placement that the studio refused before it changed the package;
/// else 2.
private func refusedCode(_ error: StudioError) -> Int32 {
    switch error {
    case .noRoute, .deviceMissing, .channelOutOfRange, .channelInUse, .microphoneAccess, .diskLow, .placementSpace,
        .appSourcesUnavailable,
        .session,
        .segment,
        .rippleBlocked:
        editRefused
    case .busy, .locked, .file, .finalize, .export, .exportYielded, .audioImport, .importYielded, .paste, .pasteYielded,
        .split, .splitYielded, .clipRender, .clipRenderYielded, .artwork, .unusedFiles, .levelCancelled,
        .duckCancelled, .readYielded, .readClosed, .transcription, .transcriptionYielded, .transcriptionCancelled,
        .duckRead,
        .writerDidNotStop:
        packageError
    }
}

/// The end of `record` and `take finalize` (decision 0013): the clip IDs of take `take` on
/// stdout, then one warning line for each unplaced segment, a disk-low stop, each armed track
/// with a gap, and each armed track with no clip of the take. Returns the lowest code that
/// applies of 3, 4, and 5, else 0.
@MainActor
func reportTake(_ studio: Studio, take: Int?, armed: [TrackID], result: TakeResult?) -> Int32 {
    var codes: [Int32] = []
    let clips = take.map { studio.clipIDs(ofTake: $0) } ?? []
    for id in clips { print(id) }
    for segment in studio.unplacedSegments {
        let newer = newerSidecarVersion(of: segment, in: studio.url).map {
            ": its sidecar was made by a newer version of Dirigible (version \($0))"
        }
        warn("\(captureFolderName)/\(segment.stem).caf is not on the timeline\(newer ?? "").")
        codes.append(unplacedAudio)
    }
    if result?.end == .diskLow {
        warn("the take stopped early because the disk is almost full.")
        codes.append(diskLowStop)
    }
    if writeGaps(result?.gaps ?? [:], armed: armed) { codes.append(trackGap) }
    // The track has a clip, so a silence line adds no exit code (A9).
    for line in silenceWarnings(result?.silent ?? [:], armed: armed) { warn(line) }
    if let take {
        for track in armed where !(studio.session.track(track)?.clips.contains { clips.contains($0.id) } ?? false) {
            warn("track \"\(track)\" has no clip from take \(take).")
            codes.append(trackGap)
        }
    }
    return codes.min() ?? 0
}

/// One line for each armed track with a gap, in arm order. True when it wrote a line.
@discardableResult
private func writeGaps(_ gaps: [TrackID: TakeResult.Gap], armed: [TrackID]) -> Bool {
    for track in armed {
        switch gaps[track] {
        case .deviceLost: warn("track \"\(track)\" lost its device during the take.")
        case .writeFailed: warn("track \"\(track)\" had a write error during the take.")
        case nil: continue
        }
    }
    return !gaps.isEmpty
}

/// A9: one line for each silent app track, in arm order.
func silenceWarnings(_ silent: [TrackID: String], armed: [TrackID]) -> [String] {
    armed.compactMap { track in
        silent[track].map {
            "track \"\(track)\" got only silence from \($0); check System Audio Recording in Privacy & Security."
        }
    }
}

private func warn(_ message: String) {
    FileHandle.standardError.write(Data("Warning: \(message)\n".utf8))
}

struct Apps: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the running apps that can be a track source.",
        discussion:
            "One line for each regular app with an audio process: the bundle ID, the name, and 1 when the app plays "
            + "sound now (else 0), split by tabs.")

    func run() { print(appLines(RunningApp.all()), terminator: "") }
}
