import DirigibleAudio
import DirigibleCore
import Foundation

/// A paste from another session package (decision 0042): the data of `clip paste --source`,
/// `clip paste-clips --source`, and `bin paste --source`, and of their MCP tools. The command and the
/// server run it in `editPackageCore`, under the lock of the target. The source is read with no lock,
/// as `info`.
package struct PasteWork: Sendable {
    package enum Selection: Sendable {
        case range(Range<Frames>, tracks: [TrackID])
        case clips([ClipID])
        /// A bin item of the source, with the pool records of the source at the paste.
        case binItem(BinItemID)
    }

    let source: URL
    let selection: Selection
    package let mode: PasteMode
    /// Checked by `EditRules.pasteTargets` and `EditRules.sourceNeedsOnto`.
    let onto: [String]

    package init(source: URL, selection: Selection, mode: PasteMode, onto: [String]) {
        (self.source, self.selection, self.mode, self.onto) = (source, selection, mode, onto)
    }

    /// Copies or converts the files of the clips into the target and pastes them (`pasteClipboard`).
    package func run(_ session: inout Session, lock: PackageLock, package: URL) throws(PasteError) -> [ClipID] {
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
            case .binItem(let item):
                excerpt = try read.excerpt(of: item)
                targets = EditRules.laneTargets(of: excerpt, onto: onto)
            }
        } catch {
            throw .session(error)
        }
        let target: URL
        do throws(SessionFileError) {
            target = try lock.package()
        } catch {
            // The target left its volume or was deleted after the lock: no file copies.
            throw .write(file: package.lastPathComponent, errno: ENOENT)
        }
        let pasted = try pasteClipboard(
            Clipboard(excerpt, package: source, origin: PackageID(lockFileOf: source)), from: source,
            into: session, in: target, identity: lock.identity, mode: mode,
            on: .tracks(targets), freeBytes: { lock.freeBytes() })
        session = pasted.session
        return pasted.clips
    }
}
