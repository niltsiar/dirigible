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
    // `AgentServer` sends only long work here.
    default: return .notOpen
    }
}
