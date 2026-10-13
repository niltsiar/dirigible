import DirigibleAudio
import DirigibleCore
import Foundation

/// Runs one long agent call on the studio of an open window (decision 0049). The job reports its
/// fraction through `report`, and a cancel of the call task stops it. A busy target refuses, as
/// in `liveCall`.
@MainActor
func liveJob(_ call: AgentCall, target: AgentTarget, report: @escaping @Sendable (Double) -> Void) async
    -> AgentReply
{
    if let busy = target.busy { return .result(text: busy.message(package: call.path), isError: true) }
    let studio = target.studio
    switch call.work {
    case .loudness(let ids):
        let clips: [Clip]
        do throws(SessionError) { clips = try loudnessClips(ids, in: studio.session) } catch {
            return .result(text: error.message, isError: true)
        }
        do throws(POSIXError) {
            let measured = try await studio.measureLoudness(clips, progress: report)
            return .result(text: zip(clips, measured).map(loudnessLine).joined(separator: "\n"), isError: false)
        } catch {
            return .result(text: error.code == .ECANCELED ? cancelledMessage : audioReadMessage(error), isError: true)
        }
    case .export(let work):
        if target.dialog { return .result(text: AgentBusy.dialog.message(package: call.path), isError: true) }
        do throws(ToolError) {
            return .result(
                text: try await liveExport(work, studio: studio, path: call.path, report: report), isError: false)
        } catch {
            return .result(text: error.message, isError: true)
        }
    // `AgentServer` sends only long work here.
    default: return .notOpen
    }
}

/// `export` and `render` through `Studio.export`: the window shows the export sheet, and a take
/// start, the sheet Cancel, or a cancel of the call ends the job with no file (decision 0049).
@MainActor
private func liveExport(
    _ work: ExportWork, studio: Studio, path: String, report: @escaping @Sendable (Double) -> Void
) async throws(ToolError) -> String {
    let session = studio.session
    let source = try work.source(in: session)
    guard let faults = await studio.exportFaults(source) else {
        throw ToolError("cannot check the audio files: the package or a file descriptor is not available.")
    }
    try work.check(faults, in: session)
    // The item at `out` now is the one that `replace` confirms.
    let confirmed = work.replace ? ConfirmedFile(at: work.url) : nil
    let result: ExportResult
    do throws(StudioError) {
        result = try await studio.export(source, work.options, to: work.url, replacing: confirmed, progress: report)
    } catch .export(.cancelled) {
        // A cancel of the call: the bridge closed, so no one reads the text.
        if Task.isCancelled { throw ToolError(cancelledMessage) }
        throw ToolError(stopMessage(studio.exportStop, noun: work.noun))
    } catch .export(let error) {
        throw ToolError(work.message(error))
    } catch {
        throw ToolError(error.message(package: path))
    }
    return try work.text(of: result, session: session, source: source)
}

/// The text of an export that the app stopped: the agent must not export again before it asks
/// the user.
private func stopMessage(_ stop: ExportStop?, noun: String) -> String {
    switch stop {
    case .user: "The user cancelled the \(noun) in Dirigible. No file was written."
    case .take: "A take started in Dirigible, so the \(noun) stopped. No file was written."
    case .close, nil: "The session window closed, so the \(noun) stopped. No file was written."
    }
}

/// The text of a long call that a stop of the agent server ended: the user turned the server off,
/// or quits.
func serverStopMessage(_ work: ToolWork) -> String {
    guard case .export(let export) = work else {
        return "Dirigible stopped its agent server, so the loudness measure stopped."
    }
    return "Dirigible stopped its agent server, so the \(export.noun) stopped. No file was written."
}
