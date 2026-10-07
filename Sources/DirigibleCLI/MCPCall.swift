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
    case .create(let sampleRate):
        do throws(SessionFileError) {
            try Session.create(at: package, sampleRate: sampleRate)
            return "OK"
        } catch {
            throw ToolError(error.message(package: path))
        }
    case .info(let tracks, let range):
        return try info(package, path: path, tracks: tracks, range: range)
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
    let view = SessionView(session, media: media).filtered(tracks: tracks.map { Set($0.map(\.rawValue)) }, range: range)
    let text: String
    do {
        text = try view.json(pretty: false)
    } catch {
        // SessionView holds only strings and numbers, so the encode does not fail.
        throw ToolError("cannot write the session as JSON: \(error.localizedDescription)")
    }
    return text.count <= sessionInfoBudget ? text : overview(of: view, size: text.count)
}

/// The largest `session_info` answer in characters, about 15,000 tokens: Claude Code refuses a
/// tool result over 25,000 tokens (U9).
let sessionInfoBudget = 60_000

/// The answer when the JSON passes the budget: each track with its clip count, the end frame of
/// the last clip, the marker count, and a note that tells how to read the session in parts. The
/// size does not grow with the clip IDs, so an agent can always read it.
private func overview(of view: SessionView, size: Int) -> String {
    let end = view.tracks.flatMap(\.clips).map { $0.start + $0.length }.max() ?? 0
    return MCPServer.encode([
        "note":
            "The session JSON has \(size) characters, more than \(sessionInfoBudget). This is an overview. Read the "
            + "session in parts: with from and to (a frame range), or with tracks.",
        "sampleRate": view.sampleRate, "end": end, "markers": view.markers.count,
        "tracks": view.tracks.map { ["id": $0.id, "name": $0.name, "clips": $0.clips.count] },
    ])
}
