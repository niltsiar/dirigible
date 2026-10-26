import DirigibleAudio
import DirigibleCore
import Foundation

/// Runs one tool call: checks the arguments, then does the work. Gives the text of the result and
/// whether it is an error. A bad argument, a refused edit, a held lock, and a pending take give
/// the English text of the CLI line (decision 0041).
extension Tool {
    /// Runs one call where it belongs: in the app through `route` (a nil route or a nil result
    /// means that no app has the package), else on the files. A local tool reads this Mac, so its
    /// call never goes to the app. `MCPServer` and the `dirigible transport` commands use it.
    func run(_ json: [String: Any], client: ClientInfo, control: CallControl, route: MCPServer.Route?) -> (
        text: String, isError: Bool
    ) {
        var routed: (text: String, isError: Bool)?
        if case .package = body { routed = route?(name, json, client, control) }
        return routed ?? call(json, control: control)
    }

    func call(_ json: [String: Any], control: CallControl) -> (text: String, isError: Bool) {
        do throws(ToolError) {
            switch body {
            case .local(let text):
                try Arguments.refuseUnknown(json, keys: [])
                return (text(), false)
            case .package(let params, let make):
                let arguments = try Arguments(json, params: params)
                return (try perform(try make(arguments), path: arguments.path, control: control), false)
            }
        } catch {
            return (error.message, true)
        }
    }
}

private func perform(_ work: ToolWork, path: String, control: CallControl) throws(ToolError) -> String {
    let package = URL(filePath: path)
    switch work {
    case .edit(let ripple, let edit):
        do throws(EditFailure<SessionError>) {
            let (ids, note) = try editPackageCore(package, ripple: ripple) { session, _ throws(SessionError) in
                try TakeWork.noted(&session, package: package, edit)
            }
            // The new IDs, one on each line, or OK; then the note.
            return ((ids.isEmpty ? ["OK"] : ids) + note).joined(separator: "\n")
        } catch {
            throw ToolError(error.message(package: path))
        }
    case .takeImport(let take, let edit):
        do throws(EditFailure<TakeImportError>) {
            let lines = try editPackageCore(package, ripple: false) { session, _ throws(TakeImportError) in
                try TranscriptWork.inTake(
                    &session, take: take, read: TakeMap.of(session, anchors: TakeAnchors.result(package)), edit)
            }
            return lines.joined(separator: "\n")
        } catch {
            throw ToolError(error.message(package: path))
        }
    case .paste(let work):
        do throws(EditFailure<PasteError>) {
            let (ids, note) = try editPackageCore(package, ripple: false) { session, lock throws(PasteError) in
                try TakeWork.noted(&session, package: package) { session throws(PasteError) in
                    try work.run(&session, lock: lock, package: package)
                }
            }
            return ((ids.isEmpty ? ["OK"] : ids.map(\.rawValue)) + note).joined(separator: "\n")
        } catch {
            throw ToolError(error.message(package: path))
        }
    case .create(let sampleRate):
        do throws(SessionFileError) {
            try Session.create(at: package, sampleRate: sampleRate)
            return "OK"
        } catch {
            throw ToolError(error.message(package: path))
        }
    case .info(let tracks, let range, let compact):
        return try info(package, path: path, tracks: tracks, range: range, compact: compact)
    case .backups:
        if let message = missingSessionFile(package, path: path) { throw ToolError(message) }
        let names = Backup.all(in: package).map(\.fileName)
        return names.isEmpty ? "No backups." : names.joined(separator: "\n")
    case .episodeInfo:
        // EpisodeView holds only strings, numbers, and a flag, so the encode does not fail.
        return (try? EpisodeView(try read(package, path: path).episode).json(pretty: false)) ?? "{}"
    case .words(let query):
        return try TranscriptWork.wordsText(try read(package, path: path), query)
    case .episode(let work):
        do throws(EditFailure<ArtworkError>) {
            try editPackageCore(package, ripple: false) { session, _ throws(ArtworkError) in
                try work.run(&session, package: package)
            }
            return "OK"
        } catch {
            throw ToolError(error.message(package: path))
        }
    case .marker(let work):
        do throws(EditFailure<MarkerEditError>) {
            return try editPackageCore(package, ripple: false) { session, _ throws(MarkerEditError) in
                try work.run(&session, package: package)
            }.rawValue
        } catch {
            throw ToolError(error.message(package: path))
        }
    case .prune(let dryRun):
        let output: PruneOutput
        do throws(EditFailure<UnusedFilesError>) {
            output = try prunePackage(package, dryRun: dryRun)
        } catch {
            throw ToolError(error.message(package: path))
        }
        // A file that did not move makes the result an error, as exit 1 of the CLI.
        let text = (output.lines + output.failed).joined(separator: "\n")
        guard output.failed.isEmpty else { throw ToolError(text) }
        return text
    case .batch(let work):
        do throws(EditFailure<BatchWork.Failure>) {
            return try work.runOnFiles(package).joined(separator: "\n")
        } catch {
            throw ToolError(error.message(package: path))
        }
    case .record:
        throw ToolError(recordOnFilesMessage(path))
    case .transport:
        throw ToolError(transportOnFilesMessage(path))
    case .loudness(let ids):
        return try loudness(package, path: path, ids: ids, control: control)
    case .export(let work):
        return try work.run(package, path: path, control: control)
    case .level(let work):
        return try work.run(package, path: path, control: control)
    case .duck(let work):
        return try work.run(package, path: path, control: control)
    case .importFile(let work):
        return try work.run(package, path: path, control: control)
    case .splitStereo(let work):
        return try work.run(package, path: path, control: control)
    case .clipRender(let work):
        return try work.run(package, path: path, control: control)
    case .chapters(let work):
        return try work.run(package, path: path)
    case .transcriptExport(let work):
        return try work.run(package, path: path)
    case .read(let work):
        return try work.run(package, path: path, control: control)
    case .takeMap(let query):
        let session = try read(package, path: path)
        do throws(TakeMapError) {
            return try TakeWork.text(
                TakeMap.of(session, anchors: TakeAnchors.result(package)), session: session, query: query)
        } catch {
            throw ToolError(error.message)
        }
    case .revert(let backup):
        do throws(EditFailure<RevertError>) {
            let note = try editPackageCore(package, ripple: false) { session, lock throws(RevertError) in
                try TakeWork.noted(&session, package: package) { session throws(RevertError) in
                    try revert(&session, to: backup, under: lock)
                }.note
            }
            return (["OK"] + note).joined(separator: "\n")
        } catch {
            throw ToolError(error.message(package: path))
        }
    }
}

/// The session of `package`, read with no lock.
private func read(_ package: URL, path: String) throws(ToolError) -> Session {
    do throws(SessionFileError) { return try Session(contentsOf: package) } catch {
        throw ToolError(error.message(package: path))
    }
}

/// `session_info`: the compact JSON of `info --json`, read with no lock, as `dirigible info`.
private func info(_ package: URL, path: String, tracks: [TrackID]?, range: Range<Frames>?, compact: Bool)
    throws(ToolError) -> String
{
    let session = try read(package, path: path)
    try checkTracks(tracks, in: session)
    let media: [FileID: MediaFault]
    do throws(POSIXError) {
        media = try checkMedia(session, package: package)
    } catch {
        throw ToolError(mediaCheckMessage(error))
    }
    let takeMap = TakeMap.of(session, anchors: TakeAnchors.result(package))
    return try infoText(session, media: media, takeMap: takeMap, tracks: tracks, range: range, compact: compact)
}

/// The `session_info` text of a session, its media faults, and its take map: the file path and
/// the live path of an agent give the same JSON (decision 0046).
func infoText(
    _ session: Session, media: [FileID: MediaFault], takeMap: TakeMapRead, tracks: [TrackID]?,
    range: Range<Frames>?, compact: Bool
) throws(ToolError) -> String {
    try checkTracks(tracks, in: session)
    let whole = SessionView(session, media: media, takeMap: takeMap)
    let view = whole.filtered(tracks: tracks.map { Set($0.map(\.rawValue)) }, range: range)
    let text: String
    do {
        text = try view.json(pretty: false, compact: compact)
    } catch {
        // SessionView holds only strings and numbers, so the encode does not fail.
        throw ToolError("cannot write the session as JSON: \(error.localizedDescription)")
    }
    guard text.count > sessionInfoBudget else { return text }
    return overview(of: view, in: whole, size: text.count, filtered: tracks != nil || range != nil)
}

/// Refuses a `session_info` track that the session does not have, before the media check.
private func checkTracks(_ tracks: [TrackID]?, in session: Session) throws(ToolError) {
    if let unknown = tracks?.first(where: { session.track($0) == nil }) {
        throw ToolError(SessionError.unknownTrack(unknown).message)
    }
}

/// The largest `session_info` answer in characters. Claude Code refuses a tool result over
/// 25,000 tokens, and a measure of session JSON with chained clip IDs gave about 2.1 characters
/// a token (decisions.tsv, M1 measure), so 40,000 characters are about 19,000 tokens.
let sessionInfoBudget = 40_000

/// The answer when the JSON passes the budget: each track of the answer with its clip count, the
/// end frame and the marker count of the whole session, and a note that tells how to read the
/// session in parts. Its size does not grow with the clip IDs, so an agent can always read it.
private func overview(of view: SessionView, in whole: SessionView, size: Int, filtered: Bool) -> String {
    let end = whole.tracks.flatMap(\.clips).map { $0.start + $0.length }.max() ?? 0
    let how =
        filtered
        ? "The answer of this filter is still too large. Read it in smaller parts with from and to."
        : "Read the session in parts: with from and to (a frame range), or with tracks."
    return MCPServer.encode([
        "note": "The JSON has \(size) characters, more than \(sessionInfoBudget). This is an overview. " + how,
        "sampleRate": whole.sampleRate, "end": end, "markers": whole.markers.count,
        "tracks": view.tracks.map { ["id": $0.id, "name": $0.name, "clips": $0.clips.count] },
    ])
}

extension MCPServer {
    /// One call of the tool `name`, with no MCP session: the commands of the CLI that need the
    /// app (`dirigible transport`) run their tool here, so they get the replies and the files
    /// refusals of `dirigible mcp` with no copy of them.
    package static func run(tool name: String, _ arguments: [String: Any], client: ClientInfo, route: Route?) -> (
        text: String, isError: Bool
    ) {
        guard let tool = Tool.all.first(where: { $0.name == name }) else { return ("no tool \(name).", true) }
        let control = CallControl(token: nil, interval: .seconds(1), send: { _ in }, poll: { _ in false }, step: {})
        return tool.run(arguments, client: client, control: control, route: route)
    }
}
