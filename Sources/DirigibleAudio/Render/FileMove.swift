import Foundation

/// Moves `source` to `target` and never replaces an item there (decision 0016, probe X1).
/// `renamex_np(RENAME_EXCL)`; where that gives ENOTSUP or EPERM (exFAT), it claims `target`
/// with `O_CREAT | O_EXCL`, then renames over the claim. A throw removes its own claim.
func moveNew(_ source: URL, to target: URL) throws(ExportError) {
    guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) != 0 else { return }
    guard errno == ENOTSUP || errno == EPERM else { throw errno == EEXIST ? .exists : .moveFailed(errno) }
    let claim = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
    guard claim >= 0 else { throw errno == EEXIST ? .exists : .moveFailed(errno) }
    close(claim)
    guard rename(source.path, target.path) == 0 else {
        let code = errno
        unlink(target.path)
        throw .moveFailed(code)
    }
}

/// The item at a path that the user confirmed to replace: its `lstat` `(st_dev, st_ino)`. A new
/// item at the same name gets another `st_ino` on APFS, exFAT, and FAT (probes P9, P9b).
public struct ConfirmedFile: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t

    /// Nil when nothing is at `url`.
    public init?(at url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}

/// Moves `source` over `target` only when `target` still is the `confirmed` item: `rename(2)`
/// replaces it atomically. An empty target gets `moveNew`. Another item at the target gives
/// `.exists`, and that item does not change. `RENAME_SWAP` is not used: FAT deletes the old
/// file (P9).
func moveOver(_ source: URL, to target: URL, confirmed: ConfirmedFile) throws(ExportError) {
    guard let current = ConfirmedFile(at: target) else { return try moveNew(source, to: target) }
    guard current == confirmed else { throw .exists }
    guard rename(source.path, target.path) == 0 else { throw .moveFailed(errno) }
}
