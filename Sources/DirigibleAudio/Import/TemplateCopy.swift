import AVFoundation
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
    /// The package that a save copies from is gone or moved (`PackageLock.package()`). A copy from a template
    /// never throws it.
    case source(SessionFileError)
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
    /// `.exists`, or a fault of `stageFolder`, `checkPublish`, the write of `session.xml` with no errno, or the
    /// rename.
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
    /// Runs after the resolve of a path in the check pass, before its open.
    var resolved: (String) -> Void = { _ in }
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
/// one space check; a copy pass from the checked descriptor, which converts the FLAC of an archived
/// pool WAV to a WAV at the pool path (decision 0072); the flush of the files, then of the
/// folders deepest first, then of the staging folder; `session.xml`; the publish. A cancel counts
/// before each file, before `session.xml`, and before the publish. A throw leaves nothing at
/// `package` and no staging folder.
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

/// The `TemplateError` of an `openChecked` fault of `path`, whose name on disk is `name`.
private func templateError(_ fault: CheckedOpenFault, path: String, name: String) -> TemplateError {
    switch fault {
    case .missing: .missing(path)
    case .notRegularFile: .notRegularFile(name)
    case .unreadable(let code): .read(.readFailed(errno: code))
    }
}

/// The pool path of a path of `NewEpisode.filePaths` in `Clips/`, else nil.
private func poolPath(of path: String) -> String? {
    let parts = path.split(separator: "/", maxSplits: 1)
    return parts.count == 2 && parts[0] == clipsFolderName ? String(parts[1]) : nil
}

/// The check pass of one path of `NewEpisode.filePaths`: `openChecked` of its name on disk, which
/// is the name that `poolFileName` gives for a pool path, and of the other name once when it is
/// missing (decision 0072). Returns the descriptor, the checked file, and the name that it opened.
private func checkTemplateFile(_ path: String, in source: URL, folder: Int32, seams: TemplateCopySeams)
    throws(TemplateError) -> (descriptor: Int32, file: CheckedFile, name: String)
{
    guard let pool = poolPath(of: path) else {
        do {
            let opened = try openChecked(path, in: folder)
            return (opened.descriptor, opened.file, path)
        } catch {
            throw templateError(error, path: path, name: path)
        }
    }
    let name = poolFileName(path: pool, in: source)
    seams.resolved(path)
    do {
        let opened = try openChecked(name, other: name.other(path: pool), in: folder)
        return (opened.descriptor, opened.file, opened.name.name)
    } catch {
        throw templateError(error, path: path, name: name.name)
    }
}

/// The steps of `copyNewEpisode` inside the staging folder `staging`.
private func fill(
    _ staging: URL, with episode: NewEpisode, from source: URL, progress: @escaping (Double) -> Void,
    isCancelled: @escaping () -> Bool, seams: TemplateCopySeams
) throws(TemplateError) {
    // A link to the package itself is followed: the user chose it.
    let packageFD = open(source.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard packageFD >= 0 else { throw .read(.readFailed(errno: errno)) }
    defer { close(packageFD) }
    // A name on disk other than its path is the FLAC of an archived pool WAV: it converts to a WAV
    // at the path, and its size is the size of that WAV.
    var (paths, checked, names, sizes): ([String], [CheckedFile], [String], [Int64]) = ([], [], [], [])
    // On a source that ignores case, `A.wav` and `a.wav` open one file. It copies once only when the staging
    // folder also ignores case; a case-sensitive one needs a copy for each spelling.
    let mergesCase = pathconf(staging.path, _PC_CASE_SENSITIVE) == 0
    for path in episode.filePaths {
        let (descriptor, file, name) = try checkTemplateFile(path, in: source, folder: packageFD, seams: seams)
        close(descriptor)
        guard seams.isDownloaded(source.appending(path: name)) else { throw .notDownloaded(path) }
        let lower = path.lowercased()
        if mergesCase, zip(paths, checked).contains(where: { $0.lowercased() == lower && $1 == file }) { continue }
        paths.append(path)
        checked.append(file)
        names.append(name)
        try sizes.append(name == path ? file.size : wavBytes(of: source.appending(path: name), path: path))
    }
    var (pairs, whole, written): ([(source: URL, size: Int64, target: URL)], [Int], Int64) = ([], [], 0)
    for index in paths.indices {
        guard names[index] == paths[index] else {
            written += sizes[index]
            continue
        }
        pairs.append((source.appending(path: paths[index]), sizes[index], staging))
        whole.append(index)
    }
    let (wholeClones, copied) = copyNeed(pairs, canClone: seams.canClone)
    var clones = paths.map { _ in false }
    for (index, clone) in zip(whole, wholeClones) { clones[index] = clone }
    if let short = spaceShortfall(bytes: copied + written, freeBytes: { seams.freeBytes(staging) }) {
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
    // The staging folder is new, so an item there is a folder of this loop under another case.
    for folder in folders where mkdir(staging.appending(path: folder).path, 0o755) != 0 && errno != EEXIST {
        throw .write(file: folder, errno: errno)
    }
    let stagingFD = open(staging.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard stagingFD >= 0 else { throw .write(file: staging.lastPathComponent, errno: errno) }
    defer { close(stagingFD) }
    let total = max(sizes.reduce(0, +), 1)
    var done: Int64 = 0
    for (index, path) in paths.enumerated() {
        guard !isCancelled() else { throw .cancelled }
        let name = names[index]
        let opened: (descriptor: Int32, file: CheckedFile)
        do throws(CheckedOpenFault) { opened = try openChecked(name, in: packageFD) } catch {
            // A package job of another process can convert a pool file between the passes.
            let moved = poolPath(of: path).map { poolFileName(path: $0, in: source).name != name } ?? false
            throw error == .missing && moved ? .sourceChanged(path) : templateError(error, path: path, name: name)
        }
        let descriptor = opened.descriptor
        defer { close(descriptor) }
        guard opened.file == checked[index] else { throw .sourceChanged(path) }
        seams.beforeCopy(path)
        let base = done
        if name == path {
            let context = CopyContext(isCancelled: isCancelled) { bytes in
                seams.written(path, bytes)
                progress(Double(base + bytes) / Double(total))
            }
            if let code = copy(descriptor, to: path, in: stagingFD, clone: clones[index], context: context) {
                throw isCancelled() ? .cancelled : .write(file: path, errno: code)
            }
        } else {
            try convertFLAC(
                source.appending(path: name), descriptor: descriptor, to: path, in: staging,
                progress: { progress((Double(base) + $0 * Double(sizes[index])) / Double(total)) },
                isCancelled: isCancelled)
        }
        if let code = seams.flush(staging.appending(path: path).path) { throw .write(file: path, errno: code) }
        // A template that changes while it copies makes nothing.
        guard let reopened = try? openChecked(name, in: packageFD) else { throw .sourceChanged(path) }
        close(reopened.descriptor)
        guard reopened.file == checked[index] else { throw .sourceChanged(path) }
        done += sizes[index]
        progress(Double(done) / Double(total))
    }
    let depth = { (folder: String) in folder.split(separator: "/").count }
    // A folder flush that the volume refuses does not stop the copy, as for an export.
    for folder in folders.sorted(by: { depth($0) != depth($1) ? depth($0) > depth($1) : $0 < $1 }) {
        _ = seams.flush(staging.appending(path: folder).path)
    }
    _ = seams.flush(staging.path)
    guard !isCancelled() else { throw .cancelled }
    do { try seams.writeSession(episode.session, staging) } catch {
        if case .writeFailed(_, let code) = error { throw .write(file: "session.xml", errno: code) }
        throw .publish(error)
    }
    guard !isCancelled() else { throw .cancelled }
}

/// The bytes of the WAV that `convertFLAC` writes for the FLAC at `url`.
private func wavBytes(of url: URL, path: String) throws(TemplateError) -> Int64 {
    guard let file = try? AVAudioFile(forReading: url) else { throw .sourceChanged(path) }
    return wavFileBytes(frames: file.length, channels: Int(file.fileFormat.channelCount))
}

/// The conversion of the FLAC at `source`, open at `descriptor`, to a clip WAV at `path` in
/// `staging` at the rate of the FLAC, through the conversion of import (`convertToWAV`).
private func convertFLAC(
    _ source: URL, descriptor: Int32, to path: String, in staging: URL, progress: @escaping (Double) -> Void,
    isCancelled: @escaping () -> Bool
) throws(TemplateError) {
    guard let input = try? AVAudioFile(forReading: source) else { throw .sourceChanged(path) }
    let result: (length: Int, gain: Gain)?
    do throws(ImportError) {
        result = try convertToWAV(
            input, descriptor: descriptor, source: source, package: staging, wav: path,
            channels: Int(input.fileFormat.channelCount), rate: input.fileFormat.sampleRate,
            into: staging.appending(path: path), progress: progress, isCancelled: isCancelled)
    } catch {
        switch error {
        case .cancelled: throw .cancelled
        case .notDownloaded: throw .notDownloaded(path)
        case .unreadable(_, let code), .write(_, .readFailed(_, let code)): throw .read(.readFailed(errno: code))
        case .write(_, .writeFailed(_, let code)): throw .write(file: path, errno: code)
        default: throw .sourceChanged(path)
        }
    }
    guard result != nil else { throw isCancelled() ? .cancelled : .sourceChanged(path) }
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
