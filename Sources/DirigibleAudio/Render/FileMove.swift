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
