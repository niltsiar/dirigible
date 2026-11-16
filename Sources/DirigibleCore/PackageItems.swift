import Foundation

/// The folder of the raw segments in a package (decision 0012).
package let captureFolderName = "Capture"

/// Throws `.unsafeItem` for an item of `package` that is a link or is not of its kind, so no read
/// follows it out of the package or waits on a FIFO: `.lock` (at most 1 link) and `session.xml` are
/// regular files, the five folders are folders, and each entry of `Artwork/`, `Capture/`, and
/// `Backups/` is a regular file. An entry of `Clips/` or `Transcripts/` can be a link, and its
/// target is a regular file, or a folder in `Clips/`. A missing item and a dangling link pass;
/// another `lstat` or listing errno throws `.unreadableItem` with that item. `checkPoolPaths`
/// checks the pool paths in a subfolder of `Clips/` after the parse.
func checkItems(of package: URL) throws(SessionFileError) {
    for name in [".lock", "session.xml"] {
        guard let info = try itemInfo(name, in: package) else { continue }
        // A hard-linked `.lock` can name the lock of another package. A volume that reports 0 links still opens.
        guard info.st_mode & S_IFMT == S_IFREG, name == "session.xml" || info.st_nlink <= 1 else {
            throw .unsafeItem(name)
        }
    }
    for name in [clipsFolderName, transcriptsFolderName, backupsFolderName, artworkFolderName, captureFolderName] {
        switch folderErrno(package.appending(path: name)) {
        case nil: continue
        case ENOTDIR: throw .unsafeItem(name)
        case let code?: throw .unreadableItem(name, errno: code)
        }
    }
    for folder in [artworkFolderName, captureFolderName, backupsFolderName, clipsFolderName, transcriptsFolderName] {
        let url = package.appending(path: folder)
        // The listing error of a missing folder has no POSIX code.
        guard try itemInfo(folder, in: package) != nil else { continue }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        } catch {
            throw .unreadableItem(folder, errno: posixCode(of: error))
        }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw .unreadableItem(folder, errno: errno) }
        defer { close(descriptor) }
        let follows = folder == clipsFolderName || folder == transcriptsFolderName
        for name in names {
            // `fstatat` on the folder descriptor walks no path for each entry: a `Clips/` folder
            // can hold thousands of files.
            var info = stat()
            guard fstatat(descriptor, name, &info, follows ? 0 : AT_SYMLINK_NOFOLLOW) == 0 else {
                // A live take renames `.take<n>.anchor.tmp` during the listing, so a gone entry
                // passes. Through a link, a missing target passes, and the read of the item reports
                // another error.
                let code = errno
                if follows || code == ENOENT { continue }
                throw .unreadableItem("\(folder)/\(name)", errno: code)
            }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFREG || (kind == S_IFDIR && folder == clipsFolderName) { continue }
            throw .unsafeItem("\(folder)/\(name)")
        }
    }
}

/// Throws `.unsafeItem` for a pool file of `session` in a subfolder of `Clips/` whose link target
/// is not a regular file: `checkItems(of:)` checks only the entries of `Clips/` itself.
func checkPoolPaths(of session: Session, in package: URL) throws(SessionFileError) {
    for file in session.files.values where file.path.contains("/") {
        let path = "\(clipsFolderName)/\(file.path)"
        if let kind = targetKind(package.appending(path: path)), kind != S_IFREG { throw .unsafeItem(path) }
    }
}

/// The kind (`S_IFMT` bits) of the target of `url`, or nil when `stat` fails. A missing item and a
/// dangling link give nil, and the read of the item reports another error.
private func targetKind(_ url: URL) -> mode_t? {
    var info = stat()
    return stat(url.path, &info) == 0 ? info.st_mode & S_IFMT : nil
}

/// Nil for a folder or a missing item (ENOENT), ENOTDIR for another kind (a link too), and the
/// `lstat` errno for another error.
func folderErrno(_ url: URL) -> Int32? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return errno == ENOENT ? nil : errno }
    return info.st_mode & S_IFMT == S_IFDIR ? nil : ENOTDIR
}

/// The `lstat` of the item `name` of `package`, or nil for a missing item.
private func itemInfo(_ name: String, in package: URL) throws(SessionFileError) -> stat? {
    var info = stat()
    guard lstat(package.appending(path: name).path, &info) == 0 else {
        let code = errno
        guard code == ENOENT else { throw .unreadableItem(name, errno: code) }
        return nil
    }
    return info
}
