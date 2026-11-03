import Foundation

extension UnusedFiles {
    /// The captures that the prune frees, sorted: the capture of each pool item whose file is on
    /// the disk, when no other pool entry of the session and no file that a clip of a holder uses
    /// names it. A pool item with no file frees nothing: its CAF can be the last copy.
    package var captures: [CaptureID] { owners.keys.sorted() }

    /// The scan with the capture files of `captures` as `.capture` items. `paths` gives the paths
    /// of a capture relative to `package` (the layout of DirigibleAudio). A path that is not a
    /// regular file in the package gives no item.
    package func listingCaptureFiles(_ paths: (CaptureID) -> [String], in package: URL) -> UnusedFiles {
        let real = package.resolvingSymlinksInPath().path
        var added: [Item] = []
        for capture in captures {
            for path in paths(capture) {
                let url = package.appending(path: path)
                var info = stat()
                guard Self.staysIn(real, url), lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                    continue
                }
                added.append(
                    Item(kind: .capture(capture), path: path, bytes: Int64(info.st_size), identity: FileIdentity(info)))
            }
        }
        return keeping((items + added).sorted { $0.path < $1.path }, owners: owners)
    }

    /// The scan with `items`, and with the captures of `owners` whose pool items are all in
    /// `items`. A capture file of another capture goes.
    func keeping(_ items: [Item], owners: [CaptureID: Set<FileID>]) -> UnusedFiles {
        let pool = Set(items.compactMap { if case .pool(let id) = $0.kind { id } else { nil } })
        let free = owners.filter { $0.value.isSubset(of: pool) }
        return UnusedFiles(
            items: items.filter { if case .capture(let capture) = $0.kind { free[capture] != nil } else { true } },
            kept: kept, damagedBackups: damagedBackups, notFiles: notFiles, owners: free)
    }

    /// The free captures of the pool `items` of `session`, each with its pool items.
    static func captureOwners(_ items: [Item], in session: Session, holders: [Session]) -> [CaptureID: Set<FileID>] {
        var owners: [CaptureID: Set<FileID>] = [:]
        for item in items {
            guard case .pool(let id) = item.kind, item.identity != nil, let capture = session.files[id]?.capture else {
                continue
            }
            owners[capture, default: []].insert(id)
        }
        for file in session.files.values {
            if let capture = file.capture, owners[capture]?.contains(file.id) == false { owners[capture] = nil }
        }
        for holder in holders {
            for id in holder.filesInUse { if let capture = holder.files[id]?.capture { owners[capture] = nil } }
        }
        return owners
    }
}
