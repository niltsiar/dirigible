import DirigibleAudio
import DirigibleCore
import Foundation

/// Runs one agent call on the studio of an open window (decision 0046 Live tools). An edit is one
/// `Studio.edit`: one undo entry with the agent name and one autosave. A read reads the studio. A
/// call that copies files, and `file_prune` (decision 0047), give the "open in Dirigible" error,
/// and `session_create` runs on the files, where the package exists.
@MainActor
func liveCall(_ call: AgentCall, target: AgentTarget) -> AgentReply {
    let (studio, path) = (target.studio, call.path)
    let refusedOpen = AgentReply.result(text: openInAppMessage(path), isError: true)
    func edit<Result>(ripple: Bool, _ body: (inout Session) throws(SessionError) -> Result) throws(StudioError)
        -> Result
    {
        if target.busy != nil { throw .busy }
        return try studio.edit(ripple: ripple, agent: call.agent, body)
    }
    do throws(StudioError) {
        switch call.work {
        case .edit(let ripple, let body):
            let revision = studio.sessionRevision
            let ids = try edit(ripple: ripple, body)
            let note = TakeWork.note(studio, after: revision, agent: call.agent)
            return .result(text: ((ids.isEmpty ? ["OK"] : ids) + note).joined(separator: "\n"), isError: false)
        case .takeImport(let take, let body):
            let read = studio.takeMap
            if let fault = read.fault(take: take, in: studio.session) {
                return .result(text: TakeImportError.anchor(fault).message, isError: true)
            }
            let lines = try edit(ripple: false) { session throws(SessionError) in try body(&session, read.map) }
            return .result(text: lines.joined(separator: "\n"), isError: false)
        case .marker(let work):
            if let image = work.image, !image.isEmpty { return refusedOpen }
            let marker: Marker
            do throws(MarkerEditError) { marker = try work.marker(from: studio.session.markers[work.id]) } catch {
                return .result(text: error.message, isError: true)
            }
            try edit(ripple: false) { session throws(SessionError) in try session.setMarker(marker) }
            return .result(text: marker.id.rawValue, isError: false)
        case .episode(let work):
            if let artwork = work.artwork, !artwork.isEmpty { return refusedOpen }
            try edit(ripple: false) { session in session.setEpisode(work.episode(from: session.episode)) }
            return .result(text: "OK", isError: false)
        case .info(let tracks, let range, let compact):
            do throws(ToolError) {
                let text = try infoText(
                    studio.session, media: studio.missingMedia, takeMap: studio.takeMap, tracks: tracks, range: range,
                    compact: compact)
                return .result(text: text, isError: false)
            } catch {
                return .result(text: error.message, isError: true)
            }
        case .episodeInfo:
            // EpisodeView holds only strings, numbers, and a flag, so the encode does not fail.
            return .result(text: (try? EpisodeView(studio.session.episode).json(pretty: false)) ?? "{}", isError: false)
        case .words(let query):
            do throws(ToolError) {
                return .result(text: try TranscriptWork.wordsText(studio.session, query), isError: false)
            } catch {
                return .result(text: error.message, isError: true)
            }
        case .takeMap(let query):
            do throws(TakeMapError) {
                return .result(
                    text: try TakeWork.text(studio.takeMap, session: studio.session, query: query), isError: false)
            } catch {
                return .result(text: error.message, isError: true)
            }
        case .backups:
            let names = studio.backups.map(\.fileName)
            return .result(text: names.isEmpty ? "No backups." : names.joined(separator: "\n"), isError: false)
        case .paste, .revert, .prune: return refusedOpen
        // `AgentServer` sends `record` to `liveRecord`, and long work to `liveJob`.
        case .create, .record, .loudness, .export, .level, .duck, .importFile, .chapters: return .notOpen
        }
    } catch .busy {
        return .result(text: (target.busy ?? .task).message(package: path), isError: true)
    } catch {
        return .result(text: error.message(package: path), isError: true)
    }
}

/// Asks the window of the package to record (decision 0048). The reply waits for the answer of
/// the user, so it is the one async live call. A target with no consent sheet runs on the files,
/// which refuse it.
@MainActor
func liveRecord(_ request: RecordRequest, _ call: AgentCall, target: AgentTarget) async -> AgentReply {
    if let busy = target.busy { return RecordAnswer.busy(busy).reply(package: call.path) }
    guard let record = target.record else { return .notOpen }
    return await record(request, call.agent, call.connection).reply(package: call.path)
}
