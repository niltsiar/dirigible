import DirigibleAudio
import DirigibleCore
import Foundation

/// The two refusals of a live edit whose body has its own error: a `StudioError` of the core,
/// and the error of the body.
private enum LiveEditError<Body: Error>: Error {
    case studio(StudioError)
    case body(Body)
}

/// Runs one agent call on the studio of an open window (decision 0046 Live tools). An edit is one
/// `Studio.edit`: one undo entry with the agent name and one autosave. A read reads the studio. A
/// call that copies files, and `file_prune` (decision 0047), give the "open in Dirigible" error,
/// and `session_create` runs on the files, where the package exists.
@MainActor
func liveCall(_ call: AgentCall, target: AgentTarget) -> AgentReply {
    let (studio, path) = (target.studio, call.path)
    let refusedOpen = AgentReply.result(text: openInAppMessage(path), isError: true)
    /// The one busy guard of a live edit.
    func refuseBusy() throws(StudioError) { if target.busy != nil { throw .busy } }
    func edit<Result>(ripple: Bool, _ body: (inout Session) throws(SessionError) -> Result) throws(StudioError)
        -> Result
    {
        try refuseBusy()
        return try studio.edit(ripple: ripple, agent: call.agent, body)
    }
    /// A live edit whose body has its own error: a studio refusal throws, and a body error comes
    /// back as `.failure`, so the case gives its own text.
    func edit<Value, Body: Error>(_ body: (inout Session) throws(Body) -> Value) throws(StudioError)
        -> Swift.Result<Value, Body>
    {
        try refuseBusy()
        do throws(LiveEditError<Body>) {
            return .success(
                try studio.edit(agent: call.agent, refused: LiveEditError.studio) {
                    session throws(LiveEditError<Body>) in
                    do throws(Body) { return try body(&session) } catch { throw .body(error) }
                })
        } catch {
            switch error {
            case .studio(let error): throw error
            case .body(let error): return .failure(error)
            }
        }
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
            let set = try edit { session throws(MarkerEditError) in try work.edit(&session) }
            switch set {
            case .success(let id): return .result(text: id.rawValue, isError: false)
            case .failure(let error): return .result(text: error.message, isError: true)
            }
        case .episode(let work):
            if let artwork = work.artwork, !artwork.isEmpty { return refusedOpen }
            try edit(ripple: false) { session in work.edit(&session) }
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
        case .batch(let work):
            let revision = studio.sessionRevision
            let results: [[String]]
            let ran = try edit { session throws(BatchWork.Failure) in
                try work.run(&session, canRipple: { studio.canRipple($0) })
            }
            switch ran {
            case .success(let value): results = value
            case .failure(let failure):
                let split = StudioError.rippleBlocked.message(package: path)
                return .result(text: failure.message(rippleBlocked: split), isError: true)
            }
            let note = TakeWork.note(studio, after: revision, agent: call.agent)
            return .result(text: (work.lines(results) + note).joined(separator: "\n"), isError: false)
        case .paste, .revert, .prune: return refusedOpen
        // `AgentServer` sends `record` to `liveRecord`, `transport` to `liveTransport`, and long work to `liveJob`.
        case .create, .record, .transport, .loudness, .export, .level, .duck, .importFile, .splitStereo, .clipRender,
            .chapters,
            .transcriptExport,
            .read, .transcribe:
            return .notOpen
        }
    } catch .busy {
        return .result(text: (target.busy ?? .task).message(package: path), isError: true)
    } catch {
        return .result(text: error.message(package: path), isError: true)
    }
}

/// Asks the window of the package to record (decision 0048). The reply waits for the answer of
/// the user, so it is an async live call, as `liveTransport`. A target with no consent sheet runs on the files,
/// which refuse it.
@MainActor
func liveRecord(_ request: RecordRequest, _ call: AgentCall, target: AgentTarget) async -> AgentReply {
    if let busy = target.busy { return RecordAnswer.busy(busy).reply(package: call.path) }
    guard let record = target.record else { return .notOpen }
    return await record(request, call.agent, call.connection).reply(package: call.path)
}
