import AVFoundation
import ArgumentParser
import DirigibleAudio
import DirigibleCore
import Foundation

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the input devices.",
        discussion:
            "One line for each device: the UID, the name, the input channels, and the nominal rate, split by tabs.")

    func run() {
        for device in InputDevice.all() {
            let name = device.name.map { $0 == "\t" || $0.isNewline ? " " : $0 }
            let rate =
                device.nominalRate.rounded() == device.nominalRate
                ? "\(Int(device.nominalRate))" : "\(device.nominalRate)"
            print("\(device.uid)\t\(String(name))\t\(device.channelCount)\t\(rate)")
        }
    }
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
        guard seconds.isFinite, seconds > 0, seconds <= 86_400 else {
            throw ValidationError("The seconds must be more than 0 and 86400 (24 h) or less.")
        }
        guard !arm.isEmpty else { throw ValidationError("Arm one track or more with --arm.") }
        guard playhead >= 0 else { throw ValidationError("The playhead must be 0 or more.") }
    }

    func run() async throws {
        try await recordTake(
            package, armed: arm.map { TrackID($0) }, playhead: Frames(playhead), duration: .seconds(seconds))
    }
}

/// Refuses a pending take before `Studio.open`, whose recovery would finalize it. Requests the
/// microphone access once when the status is not determined, and starts again (decision 0013).
@MainActor
private func recordTake(
    _ package: PackageArgument, armed: [TrackID], playhead: Frames, duration: Duration
) async throws(ExitCode) {
    guard try readPackage(package).recording == nil else {
        throw fail("\(package.path) has a take that is not finalized; open it in Dirigible first.", code: packageError)
    }
    let studio: Studio
    do {
        studio = try await Studio.open(package.url)
    } catch {
        throw fail(error.message(package: package.path), code: packageError)
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
            throw fail(error.message(package: package.path), code: startRefused(error))
        }
        writeGaps(take.gaps, armed: armed)
        throw fail("\(error.message(package: package.path)) The take is still pending.", code: packageError)
    }
    let code = reportTake(studio, take: result.take, armed: armed, result: result)
    if code != 0 { throw ExitCode(code) }
}

/// Exit 1 for a start that the take refused before it changed the package; else 2.
private func startRefused(_ error: StudioError) -> Int32 {
    switch error {
    case .noRoute, .deviceMissing, .channelOutOfRange, .channelInUse, .microphoneAccess, .diskLow, .session, .segment:
        editRefused
    case .busy, .locked, .file, .finalize, .export, .exportYielded: packageError
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
        warn("\(captureFolderName)/\(segment.stem).caf is not on the timeline.")
        codes.append(unplacedAudio)
    }
    if result?.end == .diskLow {
        warn("the take stopped early because the disk is almost full.")
        codes.append(diskLowStop)
    }
    if writeGaps(result?.gaps ?? [:], armed: armed) { codes.append(trackGap) }
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

private func warn(_ message: String) {
    FileHandle.standardError.write(Data("Warning: \(message)\n".utf8))
}
