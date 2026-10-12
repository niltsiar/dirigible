import DirigibleAudio
import DirigibleCore
import Foundation

/// Runs one agent call on the studio of an open window (decision 0046 Live tools). An edit is one
/// `Studio.edit`: one undo entry with the agent name and one autosave. A read reads the studio. A
/// call that copies files gives the "open in Dirigible" error, and `session_create` runs on the
/// files, where the package exists.
@MainActor
func liveCall(_ call: AgentCall, target: AgentTarget) -> AgentReply {
    let (studio, path) = (target.studio, call.path)
    let refusedOpen = AgentReply.result(text: openInAppMessage(path), isError: true)
    func edit<Result>(ripple: Bool = false, _ body: (inout Session) throws(SessionError) -> Result) throws(StudioError)
        -> Result
    {
        if target.busy { throw .busy }
        return try studio.edit(ripple: ripple, agent: call.agent, body)
    }
    do throws(StudioError) {
        switch call.work {
        case .edit(let ripple, let body):
            let ids = try edit(ripple: ripple, body)
            return .result(text: ids.isEmpty ? "OK" : ids.joined(separator: "\n"), isError: false)
        case .marker(let work):
            if let image = work.image, !image.isEmpty { return refusedOpen }
            let marker: Marker
            do throws(MarkerEditError) { marker = try work.marker(from: studio.session.markers[work.id]) } catch {
                return .result(text: error.message, isError: true)
            }
            try edit { session throws(SessionError) in try session.setMarker(marker) }
            return .result(text: marker.id.rawValue, isError: false)
        case .episode(let work):
            if let artwork = work.artwork, !artwork.isEmpty { return refusedOpen }
            try edit { session in session.setEpisode(work.episode(from: session.episode)) }
            return .result(text: "OK", isError: false)
        case .info(let tracks, let range):
            do throws(ToolError) {
                let text = try infoText(studio.session, media: studio.missingMedia, tracks: tracks, range: range)
                return .result(text: text, isError: false)
            } catch {
                return .result(text: error.message, isError: true)
            }
        case .episodeInfo:
            // EpisodeView holds only strings, numbers, and a flag, so the encode does not fail.
            return .result(text: (try? EpisodeView(studio.session.episode).json(pretty: false)) ?? "{}", isError: false)
        case .backups:
            let names = studio.backups.map(\.fileName)
            return .result(text: names.isEmpty ? "No backups." : names.joined(separator: "\n"), isError: false)
        case .paste, .revert: return refusedOpen
        case .create: return .notOpen
        }
    } catch {
        return .result(text: error.message(package: path), isError: true)
    }
}
