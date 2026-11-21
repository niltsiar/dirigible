import DirigibleCore
import Foundation

/// A new session: an empty session at a rate, or a copy of a template. `Studio.create`, the
/// `create` command, and the `session_create` tool take it.
public enum NewSessionSource: Hashable, Sendable {
    case rate(Int)
    case template(URL)
}

/// Why a template copy made nothing. Each `String` is a package-relative path of the template.
public enum TemplateError: Error, Hashable, Sendable {
    /// The template does not read, or is newer (0024 P3).
    case read(SessionFileError)
    /// The template has a take that is not finalized.
    case pendingTake
    /// A link at any component of the path, a FIFO, a folder, or another item that is not a file.
    case notRegularFile(String)
    /// The file has another device and inode than at the first check.
    case sourceChanged(String)
    case missing(String)
    /// An iCloud or File Provider item whose data is not on this Mac (0040).
    case notDownloaded(String)
    /// The copies need `needed` free bytes, with the 1 GB margin, and the volume has `free`.
    case space(needed: Int64, free: Int64)
    case write(file: String, errno: Int32)
    case cancelled
    /// The package name is over `templateNameLimit`.
    case nameTooLong
    /// `.exists`, or a fault of `stageFolder`, `checkPublish`, or the rename.
    case publish(SessionFileError)
}

/// The kind of the staging folder of a template copy (decision 0078).
let templateKind = "template"

/// The longest name of a template copy in UTF-8 bytes, with no ".dirigible": 193.
public let templateNameLimit = folderNameLimit(kind: templateKind) - ".dirigible".utf8.count

/// The calls of a template copy that a test replaces.
struct TemplateCopySeams {
    /// The free bytes of the volume of a folder.
    var freeBytes: (URL) -> Int64 = { folder in
        // A volume that gives no value skips the check; a full disk then stops the copy.
        Int64((try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? .max)
    }
    var canClone: (URL, URL) -> Bool = { cloneWorks($0, into: $1) }
    var isDownloaded: (URL) -> Bool = { sourceIsDownloaded($0) }
    /// Runs between the check of a path in the copy pass and its copy.
    var beforeCopy: (String) -> Void = { _ in }
    /// The `copied` callback of each data copy: the path and the bytes so far.
    var written: (String, Int64) -> Void = { _, _ in }
    /// The flush of a copied file or a folder: nil, or the errno.
    var flush: (String) -> Int32? = { fullFlush(path: $0) }
    /// The durable write of `session.xml` into the staging folder.
    var writeSession: (Session, URL) throws(SessionFileError) -> Void = { session, folder throws(SessionFileError) in
        try session.write(to: folder)
    }
}

/// The one entry point of a new session from a template: reads `template` with no lock (0024 P8),
/// applies `newEpisode()`, copies, and publishes `package`. It blocks: never call it on the main
/// actor.
public func createSession(
    at package: URL, template: URL, progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool
) throws(TemplateError) {
    try createSession(
        at: package, template: template, progress: progress, isCancelled: isCancelled, seams: TemplateCopySeams())
}

func createSession(
    at package: URL, template: URL, progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool,
    seams: TemplateCopySeams
) throws(TemplateError) {
    let session: Session
    do { session = try Session(contentsOf: template) } catch { throw .read(error) }
    let episode: NewEpisode
    do { episode = try session.newEpisode() } catch {
        throw error == .pendingTake ? .pendingTake : .read(.invalidSession(error))
    }
    try copyNewEpisode(
        episode, files: template, to: package, progress: progress, isCancelled: isCancelled, seams: seams)
}

/// The copy of `createSession` and of `Studio.saveTemplate`. It takes a `NewEpisode`, so no caller
/// can skip the rule. The order: the name limit, the staging folder, the `lstat` of `package`,
/// `checkPublish()`; a first pass that checks each file of `filePaths` on its own descriptor;
/// one space check; a copy pass from the checked descriptor; the flush of the files, then of the
/// folders deepest first, then of the staging folder; `session.xml`; the publish. A throw leaves
/// nothing at `package` and no staging folder.
func copyNewEpisode(
    _ episode: NewEpisode, files source: URL, to package: URL, progress: @escaping (Double) -> Void,
    isCancelled: @escaping () -> Bool, seams: TemplateCopySeams = TemplateCopySeams()
) throws(TemplateError) {
    guard package.lastPathComponent.utf8.count <= folderNameLimit(kind: templateKind) else { throw .nameTooLong }
    let staging: StagingFolder
    do { staging = try stageFolder(for: package, kind: templateKind) } catch { throw .publish(error) }
    var info = stat()
    if lstat(package.path, &info) == 0 {
        staging.discard()
        throw .publish(.exists)
    }
    do { try staging.checkPublish() } catch {
        staging.discard()
        throw .publish(error)
    }
    do {
        try fill(staging.url, with: episode, from: source, progress: progress, isCancelled: isCancelled, seams: seams)
    } catch {
        staging.discard()
        throw error
    }
    do { try staging.publish() } catch { throw .publish(error) }
}

/// The device and inode of a checked file, and its size.
private struct CheckedFile: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: Int64

    init(_ info: stat) {
        (device, inode, size) = (info.st_dev, info.st_ino, Int64(info.st_size))
    }
}

/// Opens `path` under `folder` with no link at any component and with no wait on a FIFO, and
/// checks that it is a regular file. The caller closes the descriptor.
private func openChecked(_ path: String, in folder: Int32) throws(TemplateError) -> (
    descriptor: Int32, file: CheckedFile
) {
    let descriptor = openat(folder, path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
        switch errno {
        case ENOENT: throw .missing(path)
        case ELOOP, ENOTDIR: throw .notRegularFile(path)
        case let code: throw .read(.readFailed(errno: code))
        }
    }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
        let code = errno
        close(descriptor)
        throw .read(.readFailed(errno: code))
    }
    guard info.st_mode & S_IFMT == S_IFREG else {
        close(descriptor)
        throw .notRegularFile(path)
    }
    return (descriptor, CheckedFile(info))
}

/// The steps of `copyNewEpisode` inside the staging folder `staging`.
private func fill(
    _ staging: URL, with episode: NewEpisode, from source: URL, progress: @escaping (Double) -> Void,
    isCancelled: @escaping () -> Bool, seams: TemplateCopySeams
) throws(TemplateError) {
    let paths = episode.filePaths
    // A link to the package itself is followed: the user chose it.
    let packageFD = open(source.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard packageFD >= 0 else { throw .read(.readFailed(errno: errno)) }
    defer { close(packageFD) }
    var checked: [CheckedFile] = []
    for path in paths {
        let (descriptor, file) = try openChecked(path, in: packageFD)
        close(descriptor)
        guard seams.isDownloaded(source.appending(path: path)) else { throw .notDownloaded(path) }
        checked.append(file)
    }
    let pairs = zip(paths, checked).map { (source: source.appending(path: $0), size: $1.size, target: staging) }
    let (clones, bytes) = copyNeed(pairs, canClone: seams.canClone)
    if let short = spaceShortfall(bytes: bytes, freeBytes: { seams.freeBytes(staging) }) {
        throw .space(needed: short.needed, free: short.free)
    }
    var folders = [clipsFolderName]
    for path in paths {
        var folder = ""
        for part in path.split(separator: "/").dropLast() {
            folder = folder.isEmpty ? String(part) : "\(folder)/\(part)"
            if !folders.contains(folder) { folders.append(folder) }
        }
    }
    for folder in folders where mkdir(staging.appending(path: folder).path, 0o755) != 0 {
        throw .write(file: folder, errno: errno)
    }
    let stagingFD = open(staging.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard stagingFD >= 0 else { throw .write(file: staging.lastPathComponent, errno: errno) }
    defer { close(stagingFD) }
    let total = max(checked.reduce(0) { $0 + $1.size }, 1)
    var done: Int64 = 0
    for (index, path) in paths.enumerated() {
        guard !isCancelled() else { throw .cancelled }
        let (descriptor, file) = try openChecked(path, in: packageFD)
        defer { close(descriptor) }
        guard file == checked[index] else { throw .sourceChanged(path) }
        seams.beforeCopy(path)
        let base = done
        let context = CopyContext(isCancelled: isCancelled) { bytes in
            seams.written(path, bytes)
            progress(Double(base + bytes) / Double(total))
        }
        if let code = copy(descriptor, to: path, in: stagingFD, clone: clones[index], context: context) {
            throw isCancelled() ? .cancelled : .write(file: path, errno: code)
        }
        if let code = seams.flush(staging.appending(path: path).path) { throw .write(file: path, errno: code) }
        // A template that changes while it copies makes nothing.
        guard let reopened = try? openChecked(path, in: packageFD) else { throw .sourceChanged(path) }
        close(reopened.descriptor)
        guard reopened.file == checked[index] else { throw .sourceChanged(path) }
        done += file.size
        progress(Double(done) / Double(total))
    }
    let depth = { (folder: String) in folder.split(separator: "/").count }
    // A folder flush that the volume refuses does not stop the copy, as for an export.
    for folder in folders.sorted(by: { depth($0) != depth($1) ? depth($0) > depth($1) : $0 < $1 }) {
        _ = seams.flush(staging.appending(path: folder).path)
    }
    _ = seams.flush(staging.path)
    do { try seams.writeSession(episode.session, staging) } catch {
        if case .writeFailed(_, let code) = error { throw .write(file: "session.xml", errno: code) }
        throw .read(error)
    }
}

/// A clone (`fclonefileat`) or a data copy (`fcopyfile` with the 0042 callback, which quits at the
/// next write after a cancel) of the open file `source` to `path` under `folder`. Returns nil, or
/// the errno.
private func copy(_ source: Int32, to path: String, in folder: Int32, clone: Bool, context: CopyContext) -> Int32? {
    if clone { return fclonefileat(source, folder, path, 0) == 0 ? nil : errno }
    let target = openat(folder, path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard target >= 0 else { return errno }
    defer { close(target) }
    guard let state = copyfile_state_alloc() else { return ENOMEM }
    defer { copyfile_state_free(state) }
    copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyCallback, to: UnsafeRawPointer.self))
    return withExtendedLifetime(context) {
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())
        return fcopyfile(source, target, state, copyfile_flags_t(COPYFILE_DATA)) == 0 ? nil : errno
    }
}
