import Foundation

/// The folder of the raw segments in a package (decision 0012).
package let captureFolderName = "Capture"

/// Throws `.unsafeItem` for an item of `package` that is a link or is not of its kind, so no read
/// follows it out of the package: `.lock` (at most 1 link) and `session.xml` are regular files, the
/// five folders are folders, and each entry of `Artwork/`, `Capture/`, and `Backups/` is a regular
/// file. A link inside `Clips/` or `Transcripts/` stays allowed. A missing item passes; another
/// `lstat` or listing errno throws `.readFailed(errno:)`.
func checkItems(of package: URL) throws(SessionFileError) {
    for name in [".lock", "session.xml"] {
        guard let info = try itemInfo(package.appending(path: name)) else { continue }
        // A hard-linked `.lock` can name the lock of another package. A volume that reports 0 links still opens.
        guard info.st_mode & S_IFMT == S_IFREG, name == "session.xml" || info.st_nlink <= 1 else {
            throw .unsafeItem(name)
        }
    }
    for name in [clipsFolderName, transcriptsFolderName, backupsFolderName, artworkFolderName, captureFolderName] {
        switch folderErrno(package.appending(path: name)) {
        case nil: continue
        case ENOTDIR: throw .unsafeItem(name)
        case let code?: throw .readFailed(errno: code)
        }
    }
    for folder in [artworkFolderName, captureFolderName, backupsFolderName] {
        let url = package.appending(path: folder)
        // The listing error of a missing folder has no POSIX code.
        guard try itemInfo(url) != nil else { continue }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        } catch {
            throw .readFailed(errno: posixCode(of: error))
        }
        // A live take renames `.take<n>.anchor.tmp` during the listing, so a gone entry passes.
        for name in names {
            guard let info = try itemInfo(url.appending(path: name)) else { continue }
            guard info.st_mode & S_IFMT == S_IFREG else { throw .unsafeItem("\(folder)/\(name)") }
        }
    }
}

/// Nil for a folder or a missing item (ENOENT), ENOTDIR for another kind (a link too), and the
/// `lstat` errno for another error.
func folderErrno(_ url: URL) -> Int32? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return errno == ENOENT ? nil : errno }
    return info.st_mode & S_IFMT == S_IFDIR ? nil : ENOTDIR
}

/// The `lstat` of `url`, or nil for a missing item.
private func itemInfo(_ url: URL) throws(SessionFileError) -> stat? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
        let code = errno
        guard code == ENOENT else { throw .readFailed(errno: code) }
        return nil
    }
    return info
}
