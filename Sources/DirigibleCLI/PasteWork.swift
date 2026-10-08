import DirigibleAudio
import DirigibleCore
import Foundation

/// A paste from another session package (decision 0042): the data of `clip paste --source` and
/// `clip paste-clips --source`, and of their MCP tools. The command and the server run it in
/// `editPackageCore`, under the lock of the target. The source is read with no lock, as `info`.
struct PasteWork: Sendable {
    enum Selection: Sendable {
        case range(Range<Frames>, tracks: [TrackID])
        case clips([ClipID])
    }

    let source: URL
    let selection: Selection
    let at: Frames
    /// Checked by `EditRules.pasteTargets` and `EditRules.sourceNeedsOnto`.
    let onto: [String]

    /// Copies or converts the files of the clips into the target and pastes them (`pasteClipboard`).
    func run(_ session: inout Session, lock: PackageLock, package: URL) throws(PasteError) -> [ClipID] {
        let read: Session
        do throws(SessionFileError) {
            read = try Session(contentsOf: source)
        } catch {
            throw .sourceMissing(file: source.lastPathComponent)
        }
        let excerpt: Excerpt
        let targets: [TrackID]
        do throws(SessionError) {
            switch selection {
            case .range(let range, let tracks):
                excerpt = try read.excerpt(of: range, on: tracks)
                targets = onto.isEmpty ? tracks : onto.map { TrackID($0) }
            case .clips(let ids):
                excerpt = try read.excerpt(of: ids)
                targets = EditRules.laneTargets(of: excerpt, onto: onto)
            }
        } catch {
            throw .session(error)
        }
        let pasted = try pasteClipboard(
            Clipboard(excerpt, package: source, origin: PackageID(lockFileOf: source)), from: source,
            into: session, in: (try? lock.package()) ?? package, identity: lock.identity, at: at,
            on: .tracks(targets), freeBytes: { lock.freeBytes() })
        session = pasted.session
        return pasted.clips
    }
}
