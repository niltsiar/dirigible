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
    /// Those tracks, then a new last track for each lane after them.
    case extending([TrackID])
    /// No track is selected: new last tracks named after the source tracks for a clipboard of
    /// another package; for a clipboard of the same package, the source tracks, and a new last track
    /// for a lane whose source track is gone.
    case unselected
}

/// Where a paste puts the clipboard, and what it does to the audio there (decisions 0042 and 0053).
public enum PasteMode: Hashable, Sendable {
    /// Paste: over the audio from the frame.
    case over(at: Frames)
    /// Insert: a ripple insert of the clipboard length on all tracks at the frame, then a paste.
    case insert(at: Frames)
    /// Replace: `Session.replace` of the range.
    case replace(Range<Frames>)
    /// Paste to Fill Selection: `Session.fill` of the range.
    case fill(Range<Frames>)

    /// True for a mode that moves later audio, so it needs the ripple rule of decision 0037.
    public var ripples: Bool {
        switch self {
        case .insert, .replace: true
        case .over, .fill: false
        }
    }
}

extension Session {
    /// The session edit of a paste of `excerpt` on `tracks` with `mode` (decision 0053). Returns the
    /// pasted IDs. A throw changes nothing.
    public mutating func paste(_ excerpt: Excerpt, mode: PasteMode, on tracks: [TrackID]) throws(SessionError)
        -> [ClipID]
    {
        switch mode {
        case .over(let at): return try paste(excerpt, at: at, on: tracks)
        case .insert(let at):
            var copy = self
            try copy.rippleInsert(excerpt.length, at: at, on: copy.tracks.map(\.id), naming: tracks)
            let pasted = try copy.paste(excerpt, at: at, on: tracks)
            self = copy
            return pasted
        case .replace(let range): return try replace(range, with: excerpt, on: tracks)
        case .fill(let range): return try fill(range, with: excerpt, on: tracks)
        }
    }
}

/// Why a paste changed nothing (decision 0042). Each `file` is a path in `Clips/` of the source.
public enum PasteError: Error, Hashable, Sendable {
    /// The source package or a source WAV is not there, or another package is at the path.
    case sourceMissing(file: String)
    /// `session.xml` of the source package does not read, with the fault of the read (a favorite add).
    case sourceUnreadable(package: String, fault: SessionFileError)
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

/// Pastes `clipboard` into a copy of `session` on `target` with `mode`, and returns that copy, the
/// pasted IDs, and the target tracks (decision 0042). For a clipboard of another package, it first
/// copies the files of the clips into `Clips/` of `package` with `copyExcerptFiles`, which gives the
/// order of the steps. It never writes `session.xml`. For another package it blocks: never call it
/// on the main actor. `isCancelled` is read in each copy callback, before each conversion block,
/// between the files, and before the renames.
public func pasteClipboard(
    _ clipboard: Clipboard, from source: URL, into session: Session, in package: URL, identity: PackageID?,
    mode: PasteMode, on target: PasteTarget, freeBytes: () -> Int64,
    canClone: (URL, URL) -> Bool = { cloneWorks($0, into: $1) }, progress: @escaping (Double) -> Void = { _ in },
    isCancelled: @escaping () -> Bool = { false }
) throws(PasteError) -> (session: Session, clips: [ClipID], tracks: [TrackID]) {
    try pasteClipboard(
        clipboard, from: source, into: session, in: package, identity: identity, mode: mode, on: target,
        freeBytes: freeBytes, canClone: canClone, progress: progress, isCancelled: isCancelled,
        flush: NewClipFiles.flushToDisk)
}

/// `pasteClipboard` with the flush of each copied file and of `Clips/` given: the tests give a fault.
/// `at` is the seam of `copyExcerptFiles`.
func pasteClipboard(
    _ clipboard: Clipboard, from source: URL, into session: Session, in package: URL, identity: PackageID?,
    mode: PasteMode, on target: PasteTarget, freeBytes: () -> Int64,
    canClone: (URL, URL) -> Bool, progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool,
    flush: @escaping (String) -> Int32?, at: (ExcerptCopyPoint) -> Void = { _ in }
) throws(PasteError) -> (session: Session, clips: [ClipID], tracks: [TrackID]) {
    let same = PackageID.same(clipboard.origin, identity)
    let pasted = try copyExcerptFiles(
        clipboard, from: source, into: session, in: package, identity: identity, freeBytes: freeBytes,
        canClone: canClone, progress: progress, isCancelled: isCancelled, flush: flush, at: at
    ) { session, excerpt throws(SessionError) in
        let plan = try PastePlan(excerpt, same: same, into: session, mode: mode, on: target)
        session = plan.session
        return (clips: plan.clips, tracks: plan.tracks)
    }
    return (pasted.session, pasted.value.clips, pasted.value.tracks)
}

/// True when a clone of `file` into `folder` can work: one volume, and a volume that can clone.
public func cloneWorks(_ file: URL, into folder: URL) -> Bool {
    var (a, b) = (stat(), stat())
    guard stat(file.path, &a) == 0, stat(folder.path, &b) == 0, a.st_dev == b.st_dev else { return false }
    return (try? folder.resourceValues(forKeys: [.volumeSupportsFileCloningKey]).volumeSupportsFileCloning) == true
}

/// Which pairs clone (`canClone(source, target folder)`), and the bytes of the pairs that do not:
/// a clone needs no space and uses clonefile, which never falls back to a copy; a data copy needs
/// the file size.
func copyNeed(_ pairs: [(source: URL, size: Int64, target: URL)], canClone: (URL, URL) -> Bool)
    -> (clones: [Bool], bytes: Int64)
{
    let clones = pairs.map { canClone($0.source, $0.target) }
    return (clones, zip(pairs, clones).reduce(0) { $0 + ($1.1 ? 0 : $1.0.size) })
}

/// The error of a `copyfile` errno. ENOENT is a missing source only when the source file is gone:
/// a target that went away is a fault of the copy.
func copyFault(_ code: Int32, from source: URL, record: AudioFile, copy: AudioFile) -> PasteError {
    code == ENOENT && access(source.path, F_OK) != 0
        ? .sourceMissing(file: record.path) : .write(file: copy.path, errno: code)
}

/// The state that the `copyfile` callback reaches through its context pointer. `copyFile` keeps it
/// alive until `copyfile` returns; `copyfile` is synchronous, so no callback runs after that.
final class CopyContext {
    let isCancelled: () -> Bool
    let copied: (Int64) -> Void

    init(isCancelled: @escaping () -> Bool, copied: @escaping (Int64) -> Void) {
        self.isCancelled = isCancelled
        self.copied = copied
    }
}

/// With `clone`, `clonefile(2)`: a clone or an error with its errno, never a silent copy (a
/// `COPYFILE_CLONE_FORCE` refusal gives ENOTSUP for every cause). Else `copyfile(3)` with a copy
/// of the data that the space check counted (probe P1). Returns nil, or the errno. The callback
/// returns `COPYFILE_QUIT` when the flag is set and at stage `COPYFILE_ERR`: with a continue
/// there, a full disk retries with no end (P1).
func copyFile(_ source: URL, to target: URL, clone: Bool, context: CopyContext) -> Int32? {
    if clone { return clonefile(source.path, target.path, 0) == 0 ? nil : errno }
    guard let state = copyfile_state_alloc() else { return ENOMEM }
    defer { copyfile_state_free(state) }
    let callback: copyfile_callback_t = copyCallback
    copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
    return withExtendedLifetime(context) {
        copyfile_state_set(
            state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())
        return copyfile(source.path, target.path, state, copyfile_flags_t(COPYFILE_DATA)) == 0
            ? nil : errno
    }
}

/// The status callback of `copyFile` and of the template copy. It is a C function pointer with no
/// isolation (AGENTS.md, Audio callbacks): it runs on the thread of the `copyfile` call.
let copyCallback: copyfile_callback_t = { _, stage, state, _, _, context in
    guard let context else { return COPYFILE_QUIT }
    let copy = Unmanaged<CopyContext>.fromOpaque(context).takeUnretainedValue()
    if stage == COPYFILE_ERR || copy.isCancelled() { return COPYFILE_QUIT }
    if stage == COPYFILE_PROGRESS {
        var bytes: off_t = 0
        copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &bytes)
        copy.copied(Int64(bytes))
    }
    return COPYFILE_CONTINUE
}
