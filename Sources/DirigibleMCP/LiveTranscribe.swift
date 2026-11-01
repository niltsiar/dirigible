import DirigibleAudio

/// `transcribe` through `Studio.transcribe`: one undo step with the agent name, after a download of
/// a missing model. A take start, the banner Cancel, the close of the window, or a cancel of the
/// call ends it with no word added (decision 0065). `report` gets the fraction of each stage.
@MainActor
func liveTranscribe(
    _ work: TranscribeWork, studio: Studio, call: AgentCall, report: @escaping @Sendable (Double) -> Void
) async -> AgentReply {
    do throws(StudioError) {
        let done = try await studio.transcribe(
            track: work.track, language: work.language, model: .catalog(work.model), name: work.name, agent: call.agent
        ) { stage in report(toolFraction(stage)) }
        let lines = TranscribeWork.lines(
            id: done.id, kept: done.kept, skipped: done.skipped, untimed: done.untimed, dropped: done.dropped)
        return .result(text: lines.joined(separator: "\n"), isError: false)
    } catch .transcriptionYielded {
        return .result(text: "Dirigible started a take, so the transcription stopped. \(noWords)", isError: true)
    } catch .transcriptionCancelled {
        // A cancel of the call task: the bridge closed, or `AgentServer` gives the server stop text.
        let text =
            Task.isCancelled
            ? cancelledMessage
            : "The user cancelled the transcription, or closed the session window, in Dirigible. \(noWords)"
        return .result(text: text, isError: true)
    } catch .busy {
        return .result(text: AgentBusy.task.message(package: call.path), isError: true)
    } catch {
        return .result(text: error.message(package: call.path), isError: true)
    }
}

/// The tool scale of a transcription stage: the download from 0 to 0.2, the transcription from
/// 0.2 to 1. MCP progress must grow, so the second stage does not start again at 0.
func toolFraction(_ stage: TranscribeProgress) -> Double {
    switch stage {
    case .download(let fraction): 0.2 * fraction
    case .check, .checked: 0
    case .transcribe(let fraction): 0.2 + 0.8 * fraction
    }
}

private let noWords = "No words were added."
