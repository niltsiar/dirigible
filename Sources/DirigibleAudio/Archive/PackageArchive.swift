import AVFoundation
import DirigibleCore
import Foundation

/// What a package job did (decision 0072).
public struct ArchiveReport: Hashable, Sendable {
    /// The pool paths that the job converted, then the `<stem>.wav` path of each WAV-backed
    /// segment (decision 0071), each in path order.
    public var converted: [String] = []
    /// The pool paths that stay in their form.
    public var kept: [String: KeptReason] = [:]
    /// The private bytes of each source, read before its unlink: the bytes that the unlinks freed.
    public var bytesFreed: Int64 = 0
    /// The bytes of each new file.
    public var bytesWritten: Int64 = 0
}

/// Why a pool file stays in its form after a package job.
public enum KeptReason: Hashable, Sendable {
    /// No item at the pool path or at its FLAC name.
    case missing
    /// The pool path does not end in ".wav".
    case notWAV
    /// The WAV is not 24-bit integer PCM at the rate of the session with the channels of its entry.
    case notArchivable
    /// Another pool file has the FLAC name of the WAV as its path, so no FLAC of the WAV can be.
    case flacNameTaken
    /// A decode fault of the source, frames or an MD5 that differ, or fewer frames than the pool
    /// entry. `frames` decoded before the fault. A POSIX I/O fault is never this: it stops the job.
    case damaged(frames: Frames)
}

/// Why a package job stopped. Each file that the job converted stays in its new form, and each
/// other file stays as it was.
public enum ArchiveFault: Error, Hashable, Sendable {
    /// The session has `<recording>`.
    case pendingTake
    /// The package is the Favorites store of this process (decision 0081).
    case favoritesStore
    /// The job needs `need` free bytes, and the volume has `free`.
    case space(need: Int64, free: Int64)
    /// An I/O fault of one file, or a file at the target name that holds other audio.
    case clip(ClipArchiveFault)
    /// The save of `session.xml`.
    case file(SessionFileError)
    /// A stop.
    case cancelled
}

/// True when the session is archived, and only then: a FLAC that an unarchive kept as damaged has
/// no attribute, so the edits run (decision 0072). It reads no file.
public func needsUnarchive(_ session: Session) -> Bool { session.archive != nil }

/// WAV to FLAC for each pool WAV of `session` (decision 0072). It refuses a pending take and the
/// Favorites store of this process, then checks the disk need. With a WAV to convert
/// (`archiveSources`), it saves the session with `archive = .flac` through `save` before the first
/// file, so an older build refuses the package before a WAV goes, and sets `session` to the saved
/// value. A damaged source stays, and the job goes on. When no file converts, it saves the session
/// with no attribute again. After each file, it writes the peak cache file of the new file in `cache` from the
/// file of the source (`PeakFile.rekey`); with no `cache`, the next pass computes the peaks again.
/// It never reads or writes `session.xml` itself. Call it off the main actor, under the package
/// lock.
public func archivePackage(
    _ session: inout Session, in package: URL, cache: URL? = nil, progress: (Double) -> Void = { _ in },
    isStopped: () -> Bool = { false }, save: (Session) throws(SessionFileError) -> URL
) throws(ArchiveFault) -> ArchiveReport {
    try archivePackage(
        &session, in: package, cache: cache, progress: progress, isStopped: isStopped, save: save,
        seams: ArchiveSeams())
}

/// FLAC to WAV for each pool file of `session` and of `also` that has a FLAC, and for the FLAC of
/// each WAV-backed segment (decision 0071), whatever the attribute says. A damaged FLAC stays,
/// and the job goes on. After the last file, it saves the session with no attribute when the
/// attribute is set, and sets `session` to the saved value. The peak cache, thread, and lock
/// rules are those of `archivePackage`.
public func unarchivePackage(
    _ session: inout Session, also: [AudioFile] = [], in package: URL, cache: URL? = nil,
    progress: (Double) -> Void = { _ in }, isStopped: () -> Bool = { false },
    save: (Session) throws(SessionFileError) -> URL
) throws(ArchiveFault) -> ArchiveReport {
    try unarchivePackage(
        &session, also: also, in: package, cache: cache, progress: progress, isStopped: isStopped, save: save,
        seams: ArchiveSeams())
}

/// The convert call of one clip file: the file, the package, the rate, and the stop check.
typealias ClipJob = (AudioFile, URL, Int, () -> Bool) throws(ClipArchiveFault) -> Bool

/// A point of a package job where the crash seam of tests can stop it.
enum ArchiveJobStep: Hashable {
    /// The refusals and the disk check passed; nothing changed.
    case checked
    /// The archive saved its attribute.
    case saved
    /// The unarchive converted its last file and did not save.
    case converted
}

/// The seams of the package jobs for tests.
struct ArchiveSeams {
    var environment = ProcessInfo.processInfo.environment
    var sizes: (URL, String) throws(ClipArchiveFault) -> FileSizes = { url, name throws(ClipArchiveFault) in
        try fileSizes(of: url, name: name)
    }
    var freeBytes: (URL) -> Int64 = { volumeFreeBytes(descriptor: -1, path: $0.path) ?? 0 }
    var archive: ClipJob = { file, package, rate, isStopped throws(ClipArchiveFault) in
        try archiveClip(file, in: package, rate: rate, isCancelled: isStopped)
    }
    var unarchive: ClipJob = { file, package, rate, isStopped throws(ClipArchiveFault) in
        try unarchiveClip(file, in: package, rate: rate, isCancelled: isStopped)
    }
    /// False stops the job after the step as a crash does: it throws `.cancelled`.
    var after: (ArchiveJobStep) -> Bool = { _ in true }
}

func archivePackage(
    _ session: inout Session, in package: URL, cache: URL? = nil, progress: (Double) -> Void, isStopped: () -> Bool,
    save: (Session) throws(SessionFileError) -> URL, seams: ArchiveSeams
) throws(ArchiveFault) -> ArchiveReport {
    guard session.recording == nil else { throw .pendingTake }
    guard Favorites.backups(for: package, environment: seams.environment) != .store else { throw .favoritesStore }
    let scan = archiveSources(of: session, in: package)
    var report = ArchiveReport()
    report.kept = scan.kept
    var sources: [(file: AudioFile, flac: String, sizes: FileSizes)] = []
    for source in scan.files {
        try sources.append((source.file, source.flac, sizes(source.wav, source.file.path, seams)))
    }
    try checkSpace(sources.map { ($0.sizes.bytes, $0.sizes.freed) }, in: package, seams: seams)
    guard seams.after(.checked) else { throw .cancelled }
    let marks = session.archive == nil && !sources.isEmpty
    if marks {
        var archived = session
        archived.archive = .flac
        try saved(archived, save)
        session = archived
    }
    guard seams.after(.saved) else { throw .cancelled }

    let clips = package.appending(path: clipsFolderName)
    for (index, source) in sources.enumerated() {
        if isStopped() { throw .cancelled }
        let path = source.file.path
        let stamp = stampOnDisk(clips.appending(path: path))
        let done: Bool
        do throws(ClipArchiveFault) {
            done = try seams.archive(source.file, package, session.sampleRate, isStopped)
        } catch {
            switch error {
            case .notArchivable: report.kept[path] = .notArchivable
            case .mismatch: report.kept[path] = .damaged(frames: decodedFrames(of: clips.appending(path: path)))
            default: throw .clip(error)
            }
            continue
        }
        guard done else { throw .cancelled }
        report.converted.append(path)
        report.bytesFreed += source.sizes.freed
        report.bytesWritten += try sizes(clips.appending(path: source.flac), source.flac, seams).bytes
        rekeyPeaks(
            of: source.file, from: stamp, to: clips.appending(path: source.flac), rate: session.sampleRate, in: cache)
        progress(Double(index + 1) / Double(sources.count))
    }
    // No file converted, so no FLAC needs the attribute that this job saved.
    if marks, report.converted.isEmpty {
        var working = session
        working.archive = nil
        try saved(working, save)
        session = working
    }
    return report
}

/// The pool WAVs of `session` that an archive converts, in path order, and the reason of each
/// other pool file that keeps its form (decision 0072): a WAV that exists, with no FLAC, of
/// packed 24-bit integer PCM at the session rate with the channels of its entry. `wav` is the
/// URL of the WAV, `flac` its FLAC name in `Clips/`. It reads the disk and opens each WAV, so the
/// confirm sheet of the app counts the files of the job.
package func archiveSources(
    of session: Session, in package: URL
) -> (files: [(file: AudioFile, wav: URL, flac: String)], kept: [String: KeptReason]) {
    var files: [(file: AudioFile, wav: URL, flac: String)] = []
    var kept: [String: KeptReason] = [:]
    for file in session.files.values.sorted(by: { $0.path < $1.path }) {
        guard let flac = archivedPath(of: file.path) else {
            kept[file.path] = .notWAV
            continue
        }
        let name = poolFileName(file, in: package)
        let wav = package.appending(path: name.name)
        if session.flacNameIsTaken(file.path) {
            // The item at the FLAC name is the file of another pool entry.
            kept[file.path] = name.form == .pool && exists(wav) ? .flacNameTaken : .missing
            continue
        }
        // A FLAC with no WAV: converted before.
        guard name.form == .pool else { continue }
        guard exists(wav) else {
            kept[file.path] = .missing
            continue
        }
        guard isArchivable(wav, rate: session.sampleRate, channels: file.layout.channelCount) else {
            kept[file.path] = .notArchivable
            continue
        }
        files.append((file, wav, flac))
    }
    return (files, kept)
}

func unarchivePackage(
    _ session: inout Session, also: [AudioFile], in package: URL, cache: URL? = nil, progress: (Double) -> Void,
    isStopped: () -> Bool, save: (Session) throws(SessionFileError) -> URL, seams: ArchiveSeams
) throws(ArchiveFault) -> ArchiveReport {
    let clips = package.appending(path: clipsFolderName)
    var report = ArchiveReport()
    var sources: [(file: AudioFile, flac: String, sizes: FileSizes)] = []
    var paths = Set<String>()
    let pool = Array(session.files.values) + also
    // The item at a FLAC name that a pool file has as its path is the file of that entry.
    let taken = Set(pool.map { $0.path.lowercased() })
    for file in pool.sorted(by: { $0.path < $1.path }) where paths.insert(file.path).inserted {
        guard let flacPath = archivedPath(of: file.path) else {
            report.kept[file.path] = .notWAV
            continue
        }
        let flac = clips.appending(path: flacPath)
        if !taken.contains(flacPath.lowercased()), exists(flac) {
            try sources.append((file, flacPath, sizes(flac, flacPath, seams)))
        } else if !exists(clips.appending(path: file.path)) {
            report.kept[file.path] = .missing
        }
    }
    for segment in soleCopySegments(in: package, clip: { "\(clipsFolderName)/\($0.stem).flac" })
    where paths.insert("\(segment.stem).wav").inserted && !taken.contains("\(segment.stem).flac".lowercased()) {
        let (path, flacPath) = ("\(segment.stem).wav", "\(segment.stem).flac")
        let flac = clips.appending(path: flacPath)
        // No pool entry names the file, so STREAMINFO gives its channels and frames.
        guard let audio = try? AVAudioFile(forReading: flac),
            let layout = ChannelLayout(channelCount: Int(audio.fileFormat.channelCount))
        else {
            report.kept[path] = .damaged(frames: 0)
            continue
        }
        let file = AudioFile(id: FileID(segment.stem), path: path, layout: layout, length: Frames(Int(audio.length)))
        try sources.append((file, flacPath, sizes(flac, flacPath, seams)))
    }
    try checkSpace(
        sources.map {
            (wavFileBytes(frames: Int64($0.file.length.count), channels: $0.file.layout.channelCount), $0.sizes.freed)
        }, in: package, seams: seams)
    guard seams.after(.checked) else { throw .cancelled }

    for (index, source) in sources.enumerated() {
        if isStopped() { throw .cancelled }
        let path = source.file.path
        let stamp = stampOnDisk(clips.appending(path: source.flac))
        let done: Bool
        do throws(ClipArchiveFault) {
            done = try seams.unarchive(source.file, package, session.sampleRate, isStopped)
        } catch {
            guard case .mismatch = error else { throw .clip(error) }
            report.kept[path] = .damaged(frames: decodedFrames(of: clips.appending(path: source.flac)))
            continue
        }
        guard done else { throw .cancelled }
        report.converted.append(path)
        report.bytesFreed += source.sizes.freed
        report.bytesWritten += try sizes(clips.appending(path: path), path, seams).bytes
        rekeyPeaks(of: source.file, from: stamp, to: clips.appending(path: path), rate: session.sampleRate, in: cache)
        progress(Double(index + 1) / Double(sources.count))
    }
    guard seams.after(.converted) else { throw .cancelled }
    if session.archive != nil {
        var working = session
        working.archive = nil
        try saved(working, save)
        session = working
    }
    return report
}

/// The sizes of one file for the disk rule.
struct FileSizes: Hashable {
    var bytes: Int64
    var allocated: Int64
    /// `ATTR_CMNEXT_PRIVATESIZE`, or nil on a volume that does not return it (HFS+, exFAT).
    var privateBytes: Int64?
    /// The bytes that an unlink of the file frees: 0 for an APFS clone. A volume with no private
    /// size has no clones, so its allocated bytes.
    var freed: Int64 { privateBytes ?? allocated }
}

/// The sizes of the file at `url` (`lstat` and `getattrlist`, no link followed). `name` names it
/// in a read fault.
func fileSizes(of url: URL, name: String) throws(ClipArchiveFault) -> FileSizes {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw .read(file: name, errno: errno) }
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
    request.forkattr = attrgroup_t(truncatingIfNeeded: ATTR_CMNEXT_PRIVATESIZE)
    // The reply: a UInt32 length, the returned attribute_set_t (five UInt32 values, the fork
    // group last), then the private size as an off_t (getattrlist(2)).
    var reply = [UInt8](repeating: 0, count: 32)
    let options = UInt32(truncatingIfNeeded: FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)
    guard getattrlist(url.path, &request, &reply, reply.count, options) == 0 else {
        throw .read(file: name, errno: errno)
    }
    let (returned, size) = reply.withUnsafeBytes {
        ($0.loadUnaligned(fromByteOffset: 20, as: UInt32.self), $0.loadUnaligned(fromByteOffset: 24, as: Int64.self))
    }
    return FileSizes(
        bytes: Int64(info.st_size), allocated: Int64(info.st_blocks) * 512,
        privateBytes: returned & UInt32(truncatingIfNeeded: ATTR_CMNEXT_PRIVATESIZE) != 0 ? size : nil)
}

/// The free bytes that a job needs (decision 0072): for each file, the WAV bytes that the unlink
/// of its source does not free, then the largest bytes that the unlink of one source frees, then
/// `diskMargin`. Each file writes its target before it unlinks its source, and a FLAC is never
/// larger than its WAV. 0 for no file.
func diskNeed(_ files: [(bytes: Int64, freed: Int64)]) -> Int64 {
    guard let largest = files.map(\.freed).max() else { return 0 }
    return files.reduce(0) { $0 + max(0, $1.bytes - $1.freed) } + largest + diskMargin
}

/// The frames that decode from the start of the audio file at `url` before the first fault or
/// the end: the frames of a damaged source in a report. 0 when the file does not open.
func decodedFrames(of url: URL) -> Frames {
    guard let file = try? AVAudioFile(forReading: url),
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockFrames)
    else { return 0 }
    var total = 0
    while (try? file.read(into: buffer, frameCount: blockFrames)) != nil, buffer.frameLength > 0 {
        total += Int(buffer.frameLength)
    }
    return Frames(total)
}

private func checkSpace(
    _ files: [(bytes: Int64, freed: Int64)], in package: URL, seams: ArchiveSeams
) throws(ArchiveFault) {
    let need = diskNeed(files)
    guard need > 0 else { return }
    let free = seams.freeBytes(package)
    guard free >= need else { throw .space(need: need, free: free) }
}

/// The peak cache stamp of the file at `url`: `stat`, as `openMedia` follows a link. Nil when
/// `stat` fails.
private func stampOnDisk(_ url: URL) -> FileStamp? {
    var info = stat()
    return stat(url.path, &info) == 0 ? FileStamp(info) : nil
}

/// Writes the peak cache file of `file` at the stamp of `target` from the file of the stamp of
/// its source.
private func rekeyPeaks(of file: AudioFile, from old: FileStamp?, to target: URL, rate: Int, in cache: URL?) {
    guard let cache, let old, let new = stampOnDisk(target) else { return }
    PeakFile.rekey(path: file.path, from: old, to: new, channels: file.layout.channelCount, rate: rate, in: cache)
}

private func saved(_ session: Session, _ save: (Session) throws(SessionFileError) -> URL) throws(ArchiveFault) {
    do throws(SessionFileError) { _ = try save(session) } catch { throw .file(error) }
}

private func sizes(_ url: URL, _ name: String, _ seams: ArchiveSeams) throws(ArchiveFault) -> FileSizes {
    do throws(ClipArchiveFault) { return try seams.sizes(url, name) } catch { throw .clip(error) }
}
