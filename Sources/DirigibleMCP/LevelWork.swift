import DirigibleAudio
import DirigibleCore
import Foundation

/// Why a level changes nothing: the session refuses it, or a cancel stops it.
package enum LevelFailure: Error {
    case session(SessionError)
    case cancelled

    package var message: String {
        switch self {
        case .session(let error): error.message
        case .cancelled: "the level was cancelled."
        }
    }
}

/// The work of a `level` call or command after its arguments are checked (decisions 0041 and
/// 0049). It is the one owner of the clip choice, the steps on the files, and the texts of
/// `dirigible level` and the `level` tool. In the app, `liveJob` runs `Studio.level`.
package struct LevelWork: Sendable {
    /// The clip IDs, or empty for every clip.
    let clips: [String]
    let mode: LevelMode

    package init(clips: [String], perTrack: Bool) {
        (self.clips, self.mode) = (clips, perTrack ? .equallyPerTrack : .eachClip)
    }

    /// The chosen clips, track by track in timeline order.
    func chosen(in session: Session) throws(SessionError) -> [ClipID] {
        let all = session.tracks.flatMap(\.clips).map(\.id)
        if let unknown = clips.first(where: { session.clip(ClipID($0)) == nil }) { throw .unknownClip(ClipID(unknown)) }
        return clips.isEmpty ? all : all.filter { clips.contains($0.rawValue) }
    }

    /// The level of the chosen clips in `session`: the stdout lines and the report line of the
    /// command. The flag is read last before the caller saves: a cancel keeps `session` as it was
    /// and throws `.cancelled`.
    package func run(
        _ session: inout Session, package: URL, progress: @escaping @Sendable (Double) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws(LevelFailure) -> (lines: [String], report: String) {
        let ids: [ClipID]
        do throws(SessionError) { ids = try chosen(in: session) } catch { throw .session(error) }
        let (leveled, levels) = autoLevel(
            Set(ids), mode, of: session, in: package, progress: progress, isCancelled: isCancelled)
        guard !isCancelled() else { throw .cancelled }
        let report = LevelReport(levels, before: session)
        session = leveled
        return (Self.lines(ids, levels), Self.text(of: report))
    }

    /// One line for each clip: the clip ID, a tab, and the new gain, "none", or "unreadable".
    static func lines(_ ids: [ClipID], _ levels: [ClipID: ClipLevel]) -> [String] {
        ids.map { id in
            switch levels[id] {
            case .leveled(_, let gain)?: "\(id)\t\(String(format: "%+.1f dB", gain.dB))"
            case .noMeasurement?, nil: "\(id)\tnone"
            case .unreadable?: "\(id)\tunreadable"
            }
        }
    }

    /// The report line: the banner text of the app without its head and the track volume sentence.
    package static func text(of report: LevelReport) -> String {
        guard !report.isEmpty else { return "No change: the clips are at the target level." }
        var text = "Clips changed: \(report.changed)."
        if report.atLimit > 0 { text += " Clips at the 20 dB limit: \(report.atLimit). Check that they have speech." }
        if report.unmeasured > 0 {
            text += " Clips with no level to measure: \(report.unmeasured). They keep their gain."
        }
        return text
    }

    /// The job of a tool call on the files, under the package lock. A level that changes no gain
    /// writes nothing.
    func run(_ package: URL, path: String, control: CallControl) throws(ToolError) -> String {
        do throws(EditFailure<LevelFailure>) {
            let result = try editPackageCore(package, ripple: false, writeUnchanged: false) {
                session, _ throws(LevelFailure) in
                try run(
                    &session, package: package, progress: { control.report($0) },
                    isCancelled: { control.isCancelled() })
            }
            return (result.lines + [result.report]).joined(separator: "\n")
        } catch .body(.cancelled) {
            // A cancelled call gets no answer, so no one reads this text.
            throw ToolError(cancelledMessage)
        } catch {
            throw ToolError(error.message(package: path))
        }
    }
}
