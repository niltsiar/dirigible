import Foundation

/// The calls of a folder publish that a test replaces. Each rename gives 0 or the errno.
struct FolderPublishSeams {
    var exclusiveRename: (String, String) -> Int32 = DirigibleCore.exclusiveRename
    var plainRename: (String, String) -> Int32 = DirigibleCore.plainRename
    /// The `VOL_CAP_INT_RENAME_EXCL` bit of the volume of a path.
    var hasExclusiveRename: (String) -> Bool = volumeHasExclusiveRename
    /// `fullFlush(path:)` of the parent folder after the rename: nil, or the errno.
    var flushFolder: (String) -> Int32? = { fullFlush(path: $0) }
    /// `open(path, flags, 0o644)`: the descriptor, or -1 and the errno.
    var openLock: (String, Int32) -> (descriptor: Int32, errno: Int32) = { path, flags in
        let descriptor = open(path, flags, 0o644)
        return (descriptor, descriptor < 0 ? errno : 0)
    }
}

/// A hidden folder beside its target that `publish()` renames to the target, so the target
/// appears whole or not at all. The lock file beside it holds an flock until `publish()` or
/// `discard()`; a staging folder whose lock file a sweep can lock is dead.
public struct StagingFolder: ~Copyable {
    public let url: URL
    let target: URL
    let lock: StagingLock
    let seams: FolderPublishSeams

    /// On a volume with no exclusive rename, renames an empty folder over an empty folder in the
    /// staging folder, the step that the publish fallback needs. A failure throws before any
    /// content is written; the caller then calls `discard()`.
    public func checkPublish() throws(SessionFileError) {
        guard !seams.hasExclusiveRename(url.path) else { return }
        let (from, to) = (url.appending(path: ".publish-test-a").path, url.appending(path: ".publish-test-b").path)
        guard mkdir(from, 0o755) == 0 else { throw .writeFailed(step: "rename test", errno: errno) }
        guard mkdir(to, 0o755) == 0 else {
            let code = errno
            rmdir(from)
            throw .writeFailed(step: "rename test", errno: code)
        }
        let code = seams.plainRename(from, to)
        rmdir(from)
        rmdir(to)
        if code != 0 { throw .writeFailed(step: "rename test", errno: code) }
    }

    /// Renames the folder to the target with `renameFolder`. A throw removes the staging folder and
    /// the lock file. After the rename it flushes the parent folder with no throw, as `exportMix`
    /// after its move: the folder is at the target. Then it removes the lock file.
    public consuming func publish() throws(SessionFileError) {
        do {
            try renameFolder(url.path, to: target.path, exclusive: seams.exclusiveRename, plain: seams.plainRename)
        } catch {
            removeFiles()
            throw error
        }
        _ = seams.flushFolder(target.deletingLastPathComponent().path)
        lock.remove()
    }

    /// Removes the staging folder and the lock file.
    public consuming func discard() { removeFiles() }

    private func removeFiles() {
        try? FileManager.default.removeItem(at: url)
        lock.remove()
    }
}

/// Renames the folder `from` to `to` with `exclusive` (`renamex_np(RENAME_EXCL)`); on ENOTSUP or EPERM,
/// claims `to` with `mkdir` and renames over the empty claim with `plain` (decision 0078). An item at `to`
/// throws `.exists` and does not change; a claim that got an item stays with it. A failed rename over the
/// claim removes the claim while it is empty. A throw leaves `from` and no folder of this call at `to`.
package func renameFolder(
    _ from: String, to: String, exclusive: (String, String) -> Int32 = exclusiveRename,
    plain: (String, String) -> Int32 = plainRename
) throws(SessionFileError) {
    let code = exclusive(from, to)
    if code == ENOTSUP || code == EPERM {
        guard mkdir(to, 0o755) == 0 else {
            let claim = errno
            throw claim == EEXIST ? .exists : .writeFailed(step: "claim", errno: claim)
        }
        let moved = plain(from, to)
        if moved != 0 {
            rmdir(to)
            throw moved == ENOTEMPTY || moved == EEXIST ? .exists : .writeFailed(step: "rename", errno: moved)
        }
    } else if code != 0 {
        throw code == EEXIST || code == ENOTEMPTY ? .exists : .writeFailed(step: "rename", errno: code)
    }
}

/// `renamex_np(RENAME_EXCL)`: 0 or the errno.
package func exclusiveRename(_ from: String, _ to: String) -> Int32 {
    renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
}

/// `rename(2)`: 0 or the errno.
package func plainRename(_ from: String, _ to: String) -> Int32 { rename(from, to) == 0 ? 0 : errno }

/// The lock file of a staging folder. The flock comes with the open (`O_EXLOCK`), so a sweep never
/// sees the file unlocked. The deinit closes it, which ends the flock; a dropped staging folder is
/// then dead, and the next sweep removes it.
final class StagingLock {
    let path: String
    private let descriptor: Int32

    init(path: String, open: (String, Int32) -> (descriptor: Int32, errno: Int32)) throws(SessionFileError) {
        let flags = O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        var (descriptor, code) = open(path, flags | O_EXLOCK | O_NONBLOCK)
        // A volume with no flock: the lock file stays unlocked, and a sweep never removes it.
        if descriptor < 0, lacksFlock(code) { (descriptor, code) = open(path, flags) }
        guard descriptor >= 0 else { throw .writeFailed(step: "lock", errno: code) }
        self.path = path
        self.descriptor = descriptor
    }

    /// Removes the file while the flock holds, so no sweep locks it first.
    func remove() { unlink(path) }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// True for the errno of an `O_EXLOCK` open on a volume with no flock: ENOTSUP or EOPNOTSUPP, two
/// values on Darwin (45 and 102).
package func lacksFlock(_ code: Int32) -> Bool { code == ENOTSUP || code == EOPNOTSUPP }

/// The longest target folder name in UTF-8 bytes whose lock file name `.<name>.<UUID>.<kind>.lock`
/// fits the 255 bytes of a file name.
public func folderNameLimit(kind: String) -> Int { 255 - 44 - kind.utf8.count }

/// Sweeps the dead staging items of `kind` beside `target`, then makes the lock file
/// `.<name>.<UUID>.<kind>.lock` and the empty folder `.<name>.<UUID>.<kind>`. The sweep removes
/// each staging folder of `kind` of any target whose lock file it can lock, and for `target`
/// only, a staging folder with no lock file and a lock file with no staging folder that it can
/// lock. An empty target folder with no lock file is never swept: it can be a folder of the user.
public func stageFolder(for target: URL, kind: String) throws(SessionFileError) -> StagingFolder {
    try stageFolder(for: target, kind: kind, seams: FolderPublishSeams())
}

func stageFolder(for target: URL, kind: String, seams: FolderPublishSeams) throws(SessionFileError) -> StagingFolder {
    let parent = target.deletingLastPathComponent()
    sweepStaging(in: parent, target: target.lastPathComponent, kind: kind)
    let url = parent.appending(path: ".\(target.lastPathComponent).\(UUID().uuidString).\(kind)")
    let lock = try StagingLock(path: url.path + ".lock", open: seams.openLock)
    guard mkdir(url.path, 0o755) == 0 else {
        let code = errno
        lock.remove()
        throw .writeFailed(step: "mkdir", errno: code)
    }
    return StagingFolder(url: url, target: target, lock: lock, seams: seams)
}

private func sweepStaging(in parent: URL, target: String, kind: String) {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return }
    let present = Set(names)
    for name in names {
        guard let owner = stagingOwner(of: name, kind: kind) else { continue }
        let path = parent.appending(path: name).path
        if owner.isLock {
            guard owner.target == target, !present.contains(String(name.dropLast(5))) else { continue }
            removeIfDead(lock: path) {}
        } else if present.contains(name + ".lock") {
            removeIfDead(lock: path + ".lock") { try? FileManager.default.removeItem(atPath: path) }
        } else if owner.target == target {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

/// The target name of a staging item `.<name>.<UUID>.<kind>` or its lock file, or nil.
private func stagingOwner(of name: String, kind: String) -> (target: String, isLock: Bool)? {
    guard name.hasPrefix(".") else { return nil }
    var rest = name.dropFirst()
    let isLock = rest.hasSuffix(".lock")
    if isLock { rest = rest.dropLast(5) }
    guard rest.hasSuffix(".\(kind)") else { return nil }
    rest = rest.dropLast(kind.count + 1)
    guard rest.count > 37, UUID(uuidString: String(rest.suffix(36))) != nil, rest.dropLast(36).last == "." else {
        return nil
    }
    return (String(rest.dropLast(37)), isLock)
}

/// Runs `remove` and removes the lock file when no other descriptor holds its flock.
private func removeIfDead(lock path: String, _ remove: () -> Void) {
    let descriptor = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
    remove()
    unlink(path)
}

/// The `VOL_CAP_INT_RENAME_EXCL` bit of the volume of `path`, read with `getattrlist` on the mount
/// point. False when the bit is not valid or cannot be read.
func volumeHasExclusiveRename(_ path: String) -> Bool {
    var volume = statfs()
    guard statfs(path, &volume) == 0 else { return false }
    let root = withUnsafeBytes(of: volume.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    var request = attrlist()
    request.bitmapcount = u_short(truncatingIfNeeded: ATTR_BIT_MAP_COUNT)
    request.volattr =
        attrgroup_t(truncatingIfNeeded: ATTR_VOL_INFO) | attrgroup_t(truncatingIfNeeded: ATTR_VOL_CAPABILITIES)
    var reply = CapabilitiesReply()
    guard getattrlist(root, &request, &reply, MemoryLayout<CapabilitiesReply>.size, 0) == 0 else { return false }
    let bit = UInt32(truncatingIfNeeded: VOL_CAP_INT_RENAME_EXCL)
    // Index 1 is VOL_CAPABILITIES_INTERFACES.
    return reply.capabilities.valid.1 & bit != 0 && reply.capabilities.capabilities.1 & bit != 0
}

/// The `getattrlist` reply of `ATTR_VOL_CAPABILITIES`: the length, then the capabilities.
private struct CapabilitiesReply {
    var length: UInt32 = 0
    var capabilities = vol_capabilities_attr_t()
}
