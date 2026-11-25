import DirigibleAudio
import DirigibleCore
import Foundation

/// `import_session` through `Studio.importSession`: one undo step with the agent name. The banner
/// Cancel or a cancel of the call ends it with no track and no new WAV (decisions 0049 and 0075).
@MainActor
func liveImportSession(
    _ work: ImportSessionWork, studio: Studio, call: AgentCall, report: @escaping @Sendable (Double) -> Void
) async -> AgentReply {
    let revision = studio.sessionRevision
    do throws(StudioError) {
        let imported = try await studio.importSession(
            work.url, at: work.at, markers: work.markers, agent: call.agent, progress: report)
        let note = TakeWork.note(studio, after: revision, agent: call.agent)
        return .result(text: (ImportSessionWork.lines(imported) + note).joined(separator: "\n"), isError: false)
    } catch .sessionImport(.paste(.cancelled), _) {
        // A cancel of the call task: the bridge closed, or `AgentServer` gives the server stop text.
        let text =
            Task.isCancelled
            ? cancelledMessage : stopMessage(studio.importStop, noun: "session import", nothing: noTrack)
        return .result(text: text, isError: true)
    } catch .sessionImportYielded {
        return .result(text: stopMessage(.take, noun: "session import", nothing: noTrack), isError: true)
    } catch .sessionImport(let error, _) {
        return .result(text: error.message(source: work.source, package: call.path), isError: true)
    } catch .busy {
        let busy: AgentBusy = studio.pendingTake != nil ? .pendingTake : .task
        return .result(text: busy.message(package: call.path), isError: true)
    } catch {
        return .refusal(error, package: call.path)
    }
}
