import DirigibleAudio
import DirigibleCore
import Foundation

/// Runs one tool call: checks the arguments, then does the work. Gives the text of the result and
/// whether it is an error. A bad argument, a refused edit, a held lock, and a pending take give
/// the English text of the CLI line (decision 0041).
extension Tool {
    func call(_ json: [String: Any]) -> (text: String, isError: Bool) {
        do throws(ToolError) {
            let arguments = try Arguments(json, params: params)
            let text = try perform(try make(arguments), path: arguments.path)
            return (text, false)
        } catch {
            return (error.message, true)
        }
    }
}

private func perform(_ work: ToolWork, path: String) throws(ToolError) -> String {
    let package = URL(filePath: path)
    switch work {
    case .edit(let ripple, let edit):
        do throws(EditFailure<SessionError>) {
            let ids = try editPackageCore(package, ripple: ripple) { session, _ throws(SessionError) -> [String] in
                try edit(&session)
            }
            // The new IDs, one on each line, or OK.
            return ids.isEmpty ? "OK" : ids.joined(separator: "\n")
        } catch {
            throw ToolError(error.message(package: path))
        }
    case .paste(let work):
        do throws(EditFailure<PasteError>) {
            let ids = try editPackageCore(package, ripple: false) { session, lock throws(PasteError) -> [ClipID] in
                try work.run(&session, lock: lock, package: package)
            }
            return ids.isEmpty ? "OK" : ids.map(\.rawValue).joined(separator: "\n")
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
    case .info(let tracks, let range):
        return try info(package, path: path, tracks: tracks, range: range)
    case .backups:
        if let message = missingSessionFile(package, path: path) { throw ToolError(message) }
        let names = Backup.all(in: package).map(\.fileName)
        return names.isEmpty ? "No backups." : names.joined(separator: "\n")
    case .episodeInfo:
        let session: Session
        do throws(SessionFileError) { session = try Session(contentsOf: package) } catch {
            throw ToolError(error.message(package: path))
        }
        // EpisodeView holds only strings, numbers, and a flag, so the encode does not fail.
        return (try? EpisodeView(session.episode).json(pretty: false)) ?? "{}"
    case .episode(let work):
        do throws(EditFailure<ArtworkError>) {
            try editPackageCore(package, ripple: false) { session, _ throws(ArtworkError) in
                try work.run(&session, package: package)
            }
            return "OK"
        } catch {
            throw ToolError(error.message(package: path))
        }
    case .revert(let backup):
        do throws(EditFailure<RevertError>) {
            try editPackageCore(package, ripple: false) { session, lock throws(RevertError) in
                try revert(&session, to: backup, under: lock)
            }
            return "OK"
        } catch {
            throw ToolError(error.message(package: path))
        }
    }
}

/// `session_info`: the compact JSON of `info --json`, read with no lock, as `dirigible info`.
private func info(_ package: URL, path: String, tracks: [TrackID]?, range: Range<Frames>?) throws(ToolError) -> String {
    let session: Session
    do throws(SessionFileError) {
        session = try Session(contentsOf: package)
    } catch {
        throw ToolError(error.message(package: path))
    }
    if let unknown = tracks?.first(where: { session.track($0) == nil }) {
        throw ToolError(SessionError.unknownTrack(unknown).message)
    }
    let media: [FileID: MediaFault]
    do throws(POSIXError) {
        media = try checkMedia(session, package: package)
    } catch {
        throw ToolError(mediaCheckMessage(error))
    }
    let whole = SessionView(session, media: media)
    let view = whole.filtered(tracks: tracks.map { Set($0.map(\.rawValue)) }, range: range)
    let text: String
    do {
        text = try view.json(pretty: false)
    } catch {
        // SessionView holds only strings and numbers, so the encode does not fail.
        throw ToolError("cannot write the session as JSON: \(error.localizedDescription)")
    }
    guard text.count > sessionInfoBudget else { return text }
    return overview(of: view, in: whole, size: text.count, filtered: tracks != nil || range != nil)
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
