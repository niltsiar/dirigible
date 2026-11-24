import DirigibleCore
import Foundation

/// The journal lines of a take start and stop (decision 0059). No line holds a track ID or a
/// track name: an arm is its 1-based number.
extension Studio {
    /// `startSteps` between `take start-request` and `take started` with the total ms, or
    /// `take start-failed` with the error case.
    func beginRecording(
        armed: [TrackID], playhead: Frames?, length: UInt64? = nil, preRoll: Int? = nil
    ) async throws(StudioError) -> (take: Int, generation: Int, stop: UInt64?) {
        let request = environment.log.begin(.take, "start-request", ["armed": .number(Int64(armed.count))])
        do throws(StudioError) {
            let started = try await startSteps(armed: armed, playhead: playhead, length: length, preRoll: preRoll)
            request.end("started")
            return started
        } catch {
            environment.log.note(.take, "start-failed", level: .error, ["error": .text(error.journalName)])
            throw error
        }
    }

    /// `take begin`, then one `take arm` line for each arm of `started`.
    func logTake(_ started: StartedTake) {
        let log = environment.log
        log.note(.take, "begin", ["take": .number(Int64(started.take)), "arms": .number(Int64(started.routes.count))])
        for route in started.routes {
            let channels = route.channels.numbers.map(String.init).joined(separator: ",")
            let fields: [(key: String, value: DiagnosticValue)] = [
                ("arm", .number(Int64(route.arm))), ("kind", .text(route.app == nil ? "device" : "app")),
                ("device", .text(route.device.name)), ("uid", .uid(route.device.uid)),
                ("rate", .number(Int64(route.device.nominalRate))), ("channels", .text(channels)),
            ]
            log.note(.take, "arm", fields: fields + (route.app.map { [("app", .text($0))] } ?? []))
        }
    }

    /// `take stop-deadline` with the names of the writers that did not finish by the deadline, and
    /// `take writer-did-not-stop` with the first, which the error names.
    func logLate(_ late: [UnfinishedWriter]) {
        guard let first = late.first else { return }
        let names = late.map(\.writer.name).joined(separator: ",")
        environment.log.note(.take, "stop-deadline", level: .error, ["missed": .text(names)])
        environment.log.note(.take, "writer-did-not-stop", level: .error, ["writer": .text(first.writer.name)])
    }

    /// `complete` with `take finalized` (the ms, the gap and the dropped frames of each arm, and
    /// from a stop the WAV bytes and the take seconds), or `take finalize-failed`.
    func completeLogged(
        _ take: Int, leavingUnreadable: Bool = false, level: Bool = false, wav: Int64? = nil, seconds: Double? = nil
    ) async throws(StudioError) {
        let arms = session.recording?.armedTracks ?? []
        let start = ContinuousClock.now
        do throws(StudioError) {
            try await complete(take, leavingUnreadable: leavingUnreadable, level: level)
        } catch {
            environment.log.note(.take, "finalize-failed", level: .error, ["error": .text(error.journalName)])
            throw error
        }
        let gaps = arms.enumerated().map { "\($0 + 1):\(lastTake?.gaps[$1].map { "\($0)" } ?? "none")" }
        let dropped = arms.enumerated().map { "\($0 + 1):\(lastTake?.droppedFrames[$1] ?? 0)" }
        var fields: [(key: String, value: DiagnosticValue)] = [
            ("take", .number(Int64(take))), ("ms", .since(start)), ("gaps", .text(gaps.joined(separator: ","))),
            ("dropped", .text(dropped.joined(separator: ","))),
        ]
        if let wav { fields.append(("wav", .number(wav))) }
        if let seconds { fields.append(("seconds", .text(String(format: "%.1f", seconds)))) }
        environment.log.note(.take, "finalized", fields: fields)
    }
}

/// `take writer-finished` of `writer` with its WAV bytes and the ms from the stop call `called` to
/// the end of its finish, for the stop and for Retry Finalize: one line for each finish, from the
/// first call after the finish ends.
func noteFinished(_ writer: DeviceWriter, since called: ContinuousClock.Instant, _ log: DiagnosticLog) {
    guard let record = writer.finishRecordToNote() else { return }
    let ms = DiagnosticValue.milliseconds((record.at - called) / .milliseconds(1))
    log.note(.take, "writer-finished", ["writer": .text(writer.name), "ms": ms, "wav": .number(writer.wavBytes)])
}

extension StudioError {
    /// The case name for a journal line, with no track ID, path, or name in it.
    var journalName: String {
        switch self {
        case .busy: "busy"
        case .locked: "locked"
        case .noRoute: "noRoute"
        case .deviceMissing: "deviceMissing"
        case .channelOutOfRange: "channelOutOfRange"
        case .channelInUse: "channelInUse"
        case .appSourcesUnavailable: "appSourcesUnavailable"
        case .session: "session"
        case .file: "file"
        case .finalize: "finalize"
        case .segment: "segment"
        case .microphoneAccess(let access): "microphoneAccess.\(access)"
        case .diskLow: "diskLow"
        case .placementSpace: "placementSpace"
        case .export: "export"
        case .exportYielded: "exportYielded"
        case .exportParts: "exportParts"
        case .exportPresets: "exportPresets"
        case .exportStems: "exportStems"
        case .template: "template"
        case .templateYielded: "templateYielded"
        case .audioImport: "audioImport"
        case .importYielded: "importYielded"
        case .paste: "paste"
        case .sessionImport: "sessionImport"
        case .sessionImportYielded: "sessionImportYielded"
        case .pasteYielded: "pasteYielded"
        case .split: "split"
        case .splitYielded: "splitYielded"
        case .clipRender: "clipRender"
        case .clipRenderYielded: "clipRenderYielded"
        case .rippleBlocked: "rippleBlocked"
        case .tooLittleVoice: "tooLittleVoice"
        case .noTargetTrack: "noTargetTrack"
        case .rangeOutsideReference: "rangeOutsideReference"
        case .matchCancelled: "matchCancelled"
        case .matchRead: "matchRead"
        case .matchFault: "matchFault"
        case .syncNoMatch: "syncNoMatch"
        case .syncFile: "syncFile"
        case .syncRead: "syncRead"
        case .syncCancelled: "syncCancelled"
        case .artwork: "artwork"
        case .unusedFiles: "unusedFiles"
        case .levelCancelled: "levelCancelled"
        case .duckCancelled: "duckCancelled"
        case .readYielded: "readYielded"
        case .readClosed: "readClosed"
        case .transcription: "transcription"
        case .transcriptionYielded: "transcriptionYielded"
        case .transcriptionCancelled: "transcriptionCancelled"
        case .duckRead: "duckRead"
        case .rideCancelled: "rideCancelled"
        case .rideRead: "rideRead"
        case .rideFault: "rideFault"
        case .silencesCancelled: "silencesCancelled"
        case .silencesRead: "silencesRead"
        case .silencesStale: "silencesStale"
        case .silencesFaults: "silencesFaults"
        case .writerDidNotStop: "writerDidNotStop"
        case .outputTermUnavailable: "outputTermUnavailable"
        case .preRollStopped: "preRollStopped"
        case .favoritesLocked: "favoritesLocked"
        case .favoritesDamaged: "favoritesDamaged"
        case .favoritesFile: "favoritesFile"
        case .favoritesCopy: "favoritesCopy"
        case .favoritesYielded: "favoritesYielded"
        case .archive: "archive"
        }
    }
}
