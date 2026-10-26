import AudioToolbox
import DirigibleAudio
import DirigibleCore
import Foundation

/// The work of a `clip_denoise` call after its arguments are checked (decisions 0054 and 0049). It
/// owns the lines and the texts of `dirigible clip denoise` and of the tool. On the files it runs
/// `renderClips` under the package lock; in the app, `liveJob` runs `Studio.renderClips`.
package struct ClipRenderWork: Sendable {
    let clips: [ClipID]
    let reduction: NoiseReduction
    /// The effect unit to load. Tests set one that does not exist.
    package var component = AudioComponentDescription.soundIsolation

    package init(clips: [ClipID], reduction: NoiseReduction) {
        (self.clips, self.reduction) = (clips, reduction)
    }

    /// The form of a reduction for the command and the tool.
    package static let reductionExpected =
        "an integer from \(NoiseReduction.range.lowerBound) to \(NoiseReduction.range.upperBound)"

    var treatment: Treatment { Treatment(.noise(reduction)) }

    /// One line for each moved clip: the clip and its new file, with a tab between them.
    package static func lines(_ clips: [RenderedClip]) -> [String] {
        clips.map { "\($0.clip)\t\($0.file)" }
    }

    /// The render of the files body, in the package that `lock` holds. A cancel read after the
    /// renames removes the new WAVs and changes nothing (decision 0049). `session` changes only on
    /// success.
    package func render(
        _ session: inout Session, in package: URL, lock: PackageLock, progress: @escaping (Double) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws(ClipRenderError) -> [RenderedClip] {
        let outcome = try renderClips(
            [(clips, treatment)], of: session, in: package, freeBytes: { lock.freeBytes() }, component: component,
            progress: progress, isCancelled: isCancelled)
        if isCancelled() {
            removeMadeFiles(outcome.made)
            throw .cancelled
        }
        session = outcome.session
        return outcome.clips
    }

    /// The job of a tool call on the files, under the package lock.
    func run(_ package: URL, path: String, control: CallControl) throws(ToolError) -> String {
        do throws(EditFailure<ClipRenderError>) {
            let (moved, note) = try editPackageCore(package, ripple: false) { session, lock throws(ClipRenderError) in
                try TakeWork.noted(&session, package: package) { session throws(ClipRenderError) -> [RenderedClip] in
                    try render(
                        &session, in: package, lock: lock, progress: { control.report($0) },
                        isCancelled: { control.isCancelled() })
                }
            }
            return (Self.lines(moved) + note).joined(separator: "\n")
        } catch {
            let message =
                switch error {
                case .body(let error): error.message
                case .file(let error): error.message(package: path)
                case .pendingTake: pendingTakeMessage(path)
                case .splitTake: splitTakeMessage(path)
                }
            throw ToolError(message)
        }
    }
}
