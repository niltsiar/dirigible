import AVFoundation
import DirigibleCore
import Foundation

/// The Copy and Cut of a window (decision 0042): the excerpt with its file records, the package path
/// at the copy, and the identity of that package. It holds no studio, no lock, and no descriptor.
public struct Clipboard: Hashable, Sendable {
    public let excerpt: Excerpt
    /// The source package path at the copy.
    public let package: URL
    /// Nil for a package with no `.lock` file: then every paste copies its files.
    public let origin: PackageID?

    public init(_ excerpt: Excerpt, package: URL, origin: PackageID?) {
        self.excerpt = excerpt
        self.package = package
        self.origin = origin
    }
}

/// Where a paste puts lane i (decision 0042).
public enum PasteTarget: Hashable, Sendable {
    case tracks([TrackID])
    /// No track is selected: new last tracks named after the source tracks for a clipboard of
    /// another package, the source tracks for a clipboard of the same package.
    case unselected
}

/// Why a paste changed nothing (decision 0042). Each `file` is a path in `Clips/` of the source.
public enum PasteError: Error, Hashable, Sendable {
    /// The source package or a source WAV is not there, or another package is at the path.
    case sourceMissing(file: String)
    /// An iCloud or File Provider item whose data is not on this Mac (0040).
    case notDownloaded(file: String)
    /// The copied header differs from the file record.
    case sourceChanged(file: String)
    /// The copies need `needed` free bytes, with the 1 GB margin, and the volume has `free`.
    case space(needed: Int64, free: Int64)
    /// A copy, a flush, or a rename fails with an errno (ENOSPC too).
    case write(file: String, errno: Int32)
    /// The conversion of a file at another sample rate fails with an errno (decision 0040).
    case convert(file: String, errno: Int32)
    case cancelled
    case session(SessionError)
}

/// Pastes `clipboard` into a copy of `session` at `start` on `target`, after a ripple insert of its
/// length on all tracks when `insert`, and returns that copy, the pasted IDs, and the target tracks
/// (decision 0042). For a clipboard of another package, it first copies each file that the clips name
/// from `Clips/` of `source` into `Clips/` of `package` under a new file ID (the stem rule of 0040):
/// a clone on one volume that can clone, else a copy; at another sample rate, the conversion of
/// import, and the clip edges scale to the nearest frame (`Excerpt.resampled`). The order: the stems
/// and the session edit on a copy (a refusal moves no byte), the source and space checks, the copies
/// or conversions into `.<stem>.wav.tmp` with a flush and a read-back, the session edit again with the
/// real converted lengths, the cancel check, the renames, the flush of `Clips/`. It never writes
/// `session.xml`. A throw before the first rename leaves no new name in `Clips/`; after it, nothing
/// deletes a renamed WAV (0040). For another package it blocks: never call it on the main actor.
/// `isCancelled` is read in each copy callback, before each conversion block, between the files, and
/// before the renames.
public func pasteClipboard(
    _ clipboard: Clipboard, from source: URL, into session: Session, in package: URL, identity: PackageID?,
    at start: Frames, on target: PasteTarget, insert: Bool = false, freeBytes: () -> Int64,
    canClone: (URL, URL) -> Bool = { cloneWorks($0, into: $1) }, progress: @escaping (Double) -> Void = { _ in },
    isCancelled: @escaping () -> Bool = { false }
) throws(PasteError) -> (session: Session, clips: [ClipID], tracks: [TrackID]) {
    let excerpt = clipboard.excerpt
    let same = PackageID.same(clipboard.origin, identity)
    let rate = session.sampleRate
    let converts = !same && excerpt.sampleRate != rate
    if same, case .unselected = target, !excerpt.lanes.allSatisfy({ session.track($0.source) != nil }) {
        return (session, [], [])  // The fallback of a same-package paste today: the source tracks, or nothing.
    }
    // The scale rule has one owner: `Excerpt.resampled` gives the predicted converted lengths.
    let predicted = (converts ? excerpt.resampled(to: rate, lengths: [:]) : excerpt).files.mapValues(\.length)
    let plan: PastePlan
    do throws(SessionError) {
        plan = try PastePlan(
            excerpt, same: same, into: session, in: package, at: start, on: target, insert: insert,
            lengths: predicted, gains: [:], stems: nil)
    } catch {
        throw .session(error)
    }
    guard !plan.copies.isEmpty else { return (plan.session, plan.clips, plan.tracks) }
    if clipboard.origin != nil, !PackageID.same(PackageID(lockFileOf: source), clipboard.origin) {
        throw .sourceMissing(file: source.lastPathComponent)
    }
    var final = plan
    try copyFiles(
        plan.copies, from: source, to: package, rate: converts ? rate : nil, freeBytes: freeBytes, canClone: canClone,
        progress: progress, isCancelled: isCancelled
    ) { (converted: [FileID: (length: Frames, gain: Gain)]) throws(PasteError) in
        guard converts else { return }
        // The real lengths differ from the prediction by 1 frame at most: edit again, before the renames.
        do throws(SessionError) {
            final = try PastePlan(
                excerpt, same: false, into: session, in: package, at: start, on: target, insert: insert,
                lengths: converted.mapValues(\.length), gains: converted.mapValues(\.gain),
                stems: Dictionary(uniqueKeysWithValues: plan.copies.map { ($0.record.id, $0.copy.id.rawValue) }))
        } catch {
            throw .session(error)
        }
    }
    return (final.session, final.clips, final.tracks)
}

/// The session half of `pasteClipboard`: the target tracks, the new file records, the scale at
/// another rate, the map, and the paste, on a copy of the session.
struct PastePlan {
    var session: Session
    var clips: [ClipID] = []
    var tracks: [TrackID] = []
    /// The source record and the new record of each file to copy, in the order of the source IDs.
    var copies: [(record: AudioFile, copy: AudioFile)] = []

    /// `lengths` and `gains` are by source file ID. `stems` keeps the stems of an earlier plan.
    init(
        _ excerpt: Excerpt, same: Bool, into session: Session, in package: URL, at start: Frames,
        on target: PasteTarget, insert: Bool, lengths: [FileID: Frames], gains: [FileID: Gain],
        stems: [FileID: String]?
    ) throws(SessionError) {
        self.session = session
        switch target {
        case .tracks(let ids): tracks = ids
        case .unselected where same: tracks = excerpt.lanes.map(\.source)
        case .unselected:
            for lane in excerpt.lanes {
                let id = TrackID()
                try self.session.addTrack(id, name: lane.name, layout: lane.layout)
                tracks.append(id)
            }
        }
        var pasted = excerpt
        if !same {
            if excerpt.sampleRate != session.sampleRate {
                pasted = excerpt.resampled(to: session.sampleRate, lengths: lengths, gains: gains)
            }
            var records: [FileID: AudioFile] = [:]
            for id in excerpt.files.keys.sorted() {
                guard let record = excerpt.files[id] else { continue }
                let stem = stems?[id] ?? importStem(of: URL(filePath: record.path), in: self.session, package: package)
                let copy = AudioFile(
                    id: FileID(stem), path: "\(stem).wav", layout: record.layout, length: lengths[id] ?? record.length)
                try self.session.addFile(copy)
                records[id] = copy
                copies.append((record, copy))
            }
            pasted = try pasted.mapped(to: records)
        }
        if insert { try self.session.rippleInsert(pasted.length, at: start, on: self.session.tracks.map(\.id)) }
        clips = try self.session.paste(pasted, at: start, on: tracks)
    }
}

/// True when a clone of `file` into `folder` can work: one volume, and a volume that can clone.
public func cloneWorks(_ file: URL, into folder: URL) -> Bool {
    var (a, b) = (stat(), stat())
    guard stat(file.path, &a) == 0, stat(folder.path, &b) == 0, a.st_dev == b.st_dev else { return false }
    return (try? folder.resourceValues(forKeys: [.volumeSupportsFileCloningKey]).volumeSupportsFileCloning) == true
}

/// The file half of `pasteClipboard`: the checks, the copies or conversions (at `rate`), the
/// read-back, `beforeRenames` with the frames and the gain of each converted file, and the renames.
private func copyFiles(
    _ copies: [(record: AudioFile, copy: AudioFile)], from source: URL, to package: URL, rate: Int?,
    freeBytes: () -> Int64, canClone: (URL, URL) -> Bool, progress: @escaping (Double) -> Void,
    isCancelled: @escaping () -> Bool,
    beforeRenames: ([FileID: (length: Frames, gain: Gain)]) throws(PasteError) -> Void
) throws(PasteError) {
    let clips = package.appending(path: clipsFolderName)
    if mkdir(clips.path, 0o755) != 0, errno != EEXIST { throw .write(file: clipsFolderName, errno: errno) }
    var sizes: [Int64] = []
    var needed: Int64 = 0
    for (record, copy) in copies {
        let url = source.appending(path: "\(clipsFolderName)/\(record.path)")
        guard sourceIsDownloaded(url) else { throw .notDownloaded(file: record.path) }
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw errno == ENOENT ? .sourceMissing(file: record.path) : .write(file: record.path, errno: errno)
        }
        sizes.append(Int64(info.st_size))
        if rate != nil {
            needed += Int64(copy.length.count) * Int64(copy.layout.channelCount) * 3  // the 0040 rule
        } else if !canClone(url, clips) {
            needed += Int64(info.st_size)
        }
    }
    // One check for all files, so a paste cannot pass file by file and fill the disk late.
    if needed > 0 {
        let free = freeBytes()
        guard free >= needed + diskMargin else { throw .space(needed: needed + diskMargin, free: free) }
    }
    var temporaries: [URL] = []
    var renamed = 0
    defer { for url in temporaries.dropFirst(renamed) { unlink(url.path) } }
    let total = max(sizes.reduce(0, +), 1)
    var done: Int64 = 0
    var converted: [FileID: (length: Frames, gain: Gain)] = [:]
    for ((record, copy), size) in zip(copies, sizes) {
        guard !isCancelled() else { throw .cancelled }
        let from = source.appending(path: "\(clipsFolderName)/\(record.path)")
        let temporary = clips.appending(path: temporaryWAV(of: (copy.path as NSString).deletingPathExtension))
        temporaries.append(temporary)
        let base = done
        if let rate {
            let share = { (fraction: Double) in progress((Double(base) + fraction * Double(size)) / Double(total)) }
            converted[record.id] = try convert(
                from, record: record, copy: copy, rate: rate, into: temporary, package: package, progress: share,
                isCancelled: isCancelled)
        } else {
            let context = CopyContext(isCancelled: isCancelled) { progress(Double(base + $0) / Double(total)) }
            if let code = copyFile(from, to: temporary, context: context) {
                if code == ECANCELED { throw .cancelled }
                throw code == ENOENT ? .sourceMissing(file: record.path) : .write(file: copy.path, errno: code)
            }
            if let code = fullFlush(path: temporary.path) { throw .write(file: copy.path, errno: code) }
            guard let read = try? AVAudioFile(forReading: temporary),
                read.length == AVAudioFramePosition(copy.length.count),
                Int(read.fileFormat.channelCount) == copy.layout.channelCount
            else { throw .sourceChanged(file: record.path) }
        }
        done += size
        progress(Double(done) / Double(total))
    }
    try beforeRenames(converted)
    guard !isCancelled() else { throw .cancelled }
    for ((_, copy), temporary) in zip(copies, temporaries) {
        do throws(ExportError) {
            try moveNew(temporary, to: clips.appending(path: copy.path))
        } catch {
            if case .moveFailed(let code) = error { throw .write(file: copy.path, errno: code) }
            throw .write(file: copy.path, errno: EEXIST)
        }
        renamed += 1
    }
    if let code = fullFlush(path: clips.path) { throw .write(file: clipsFolderName, errno: code) }
}

/// One conversion of a pool WAV into `temporary` at `rate`, through the conversion of import
/// (`convertToWAV`, 0040). `ClipConversion` flushes the WAV and reads its length back.
private func convert(
    _ source: URL, record: AudioFile, copy: AudioFile, rate: Int, into temporary: URL, package: URL,
    progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool
) throws(PasteError) -> (length: Frames, gain: Gain) {
    do throws(ImportError) {
        let (descriptor, input) = try openAudio(source)
        defer { close(descriptor) }
        guard Int(input.fileFormat.channelCount) == record.layout.channelCount, input.length == record.length.count
        else { throw .notAudio(file: record.path) }
        guard
            let (length, gain) = try convertToWAV(
                input, descriptor: descriptor, source: source, package: package,
                wav: "\(clipsFolderName)/\(copy.path)", channels: record.layout.channelCount, rate: Double(rate),
                into: temporary, progress: progress, isCancelled: isCancelled)
        else { throw isCancelled() ? .cancelled : .notAudio(file: record.path) }
        return (Frames(length), gain)
    } catch {
        switch error {
        case .cancelled: throw .cancelled
        case .notAudio, .tooManyChannels: throw .sourceChanged(file: record.path)
        case .notDownloaded: throw .notDownloaded(file: record.path)
        case .unreadable(_, let code):
            throw code == ENOENT ? .sourceMissing(file: record.path) : .convert(file: record.path, errno: code)
        case .write(_, .readFailed(_, let code)), .write(_, .segmentUnreadable(_, _, let code)):
            throw .convert(file: copy.path, errno: code)
        case .write(_, .writeFailed(_, let code)):
            // A full disk keeps its own alert, as for a copy.
            throw code == ENOSPC ? .write(file: copy.path, errno: code) : .convert(file: copy.path, errno: code)
        case .space, .session: throw .convert(file: copy.path, errno: EIO)
        }
    }
}

/// The state that the `copyfile` callback reaches through its context pointer. `copyFile` keeps it
/// alive until `copyfile` returns; `copyfile` is synchronous, so no callback runs after that.
final class CopyContext {
    let isCancelled: () -> Bool
    let copied: (Int64) -> Void
    /// The number of callbacks, for the tests.
    var calls = 0

    init(isCancelled: @escaping () -> Bool, copied: @escaping (Int64) -> Void) {
        self.isCancelled = isCancelled
        self.copied = copied
    }
}

/// `copyfile(3)` with `COPYFILE_CLONE`: a clone on one volume that can clone, else a copy of the data
/// (probe P1). Returns nil, or the errno. The callback returns `COPYFILE_QUIT` when the flag is set
/// and at stage `COPYFILE_ERR`: with a continue there, a full disk retries with no end (P1).
func copyFile(_ source: URL, to target: URL, context: CopyContext) -> Int32? {
    guard let state = copyfile_state_alloc() else { return ENOMEM }
    defer { copyfile_state_free(state) }
    let callback: copyfile_callback_t = copyCallback
    copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
    return withExtendedLifetime(context) {
        copyfile_state_set(
            state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())
        return copyfile(source.path, target.path, state, copyfile_flags_t(COPYFILE_CLONE | COPYFILE_DATA)) == 0
            ? nil : errno
    }
}

/// The status callback of `copyFile`. It is a C function pointer with no isolation (AGENTS.md,
/// Audio callbacks): it runs on the thread of the `copyfile` call.
private let copyCallback: copyfile_callback_t = { _, stage, state, _, _, context in
    guard let context else { return COPYFILE_QUIT }
    let copy = Unmanaged<CopyContext>.fromOpaque(context).takeUnretainedValue()
    copy.calls += 1
    if stage == COPYFILE_ERR || copy.isCancelled() { return COPYFILE_QUIT }
    if stage == COPYFILE_PROGRESS {
        var bytes: off_t = 0
        copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &bytes)
        copy.copied(Int64(bytes))
    }
    return COPYFILE_CONTINUE
}
