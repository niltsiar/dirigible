import DirigibleAudio
import DirigibleCore
import Foundation

/// `clip_sync` through `Studio.syncClip`: one undo step with the agent name. The banner Cancel or a
/// cancel of the call ends it with no move (decisions 0049 and 0076). A moved clip with take audio
/// adds the take sync lines (decision 0061).
@MainActor
func liveSync(
    _ work: SyncWork, studio: Studio, call: AgentCall, report: @escaping @Sendable (Double) -> Void
) async -> AgentReply {
    let revision = studio.sessionRevision
    do throws(SyncRefusal) {
        let within = try work.withinFrames(rate: studio.session.sampleRate)
        do throws(StudioError) {
            let (result, headCut) = try await studio.syncClip(
                work.clip, to: work.track, within: within, agent: call.agent, progress: report)
            let moved = SyncWork.Moved(
                clip: work.clip, result: result, headCut: headCut, sampleRate: studio.session.sampleRate)
            let note = TakeWork.note(studio, after: revision, agent: call.agent)
            return .result(text: (moved.lines + note).joined(separator: "\n"), isError: false)
        } catch {
            throw SyncWork.refusal(error, in: studio.session)
        }
    } catch .studio(.syncCancelled) {
        // A cancel of the call task: the bridge closed, or `AgentServer` gives the server stop text.
        let text = Task.isCancelled ? cancelledMessage : "The user cancelled the sync in Dirigible. No clip moved."
        return .result(text: text, isError: true)
    } catch .studio(.busy) {
        return .result(text: AgentBusy.task.message(package: call.path), isError: true)
    } catch {
        return .result(text: error.message(package: call.path), isError: true)
    }
}
