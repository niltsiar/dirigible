import DirigibleAudio
import DirigibleCore
import Foundation

/// The work of a `clip_split_stereo` call after its arguments are checked (decisions 0049 and 0053).
/// It owns the lines of `dirigible clip split-stereo` and of the tool. On the files it runs the pair
/// writer `splitStereo` under the package lock; in the app, `liveJob` runs `Studio.splitStereo`.
package struct SplitWork: Sendable {
    /// The suffixes of the new track names for each caller but the window, in every language.
    package static let names = (left: "L", right: "R")

    let clips: [ClipID]

    /// One line for each source clip: its left clip, right clip, left track, and right track, with a
    /// tab between them.
    package static func lines(_ parts: [SplitPart]) -> [String] {
        parts.map { "\($0.left)\t\($0.right)\t\($0.leftTrack)\t\($0.rightTrack)" }
    }

    /// The job of a tool call on the files, under the package lock. The cancel read before the save
    /// removes the WAVs and writes nothing (decision 0049).
    func run(_ package: URL, path: String, control: CallControl) throws(ToolError) -> String {
        do throws(EditFailure<SplitError>) {
            let (parts, note) = try editPackageCore(package, ripple: false, log: control.log) {
                session, lock throws(SplitError) in
                try TakeWork.noted(&session, package: package) { session throws(SplitError) -> [SplitPart] in
                    let split = try splitStereo(
                        clips, names: Self.names, of: session, in: package, freeBytes: { lock.freeBytes() },
                        progress: { control.report($0) }, isCancelled: { control.isCancelled() })
                    if control.isCancelled() {
                        removeMadeFiles(split.made)
                        throw .cancelled
                    }
                    session = split.session
                    return split.parts
                }
            }
            return (Self.lines(parts) + note).joined(separator: "\n")
        } catch {
            throw ToolError(error.message(package: path))
        }
    }
}
