import AVFoundation
import DirigibleCore
import Foundation

/// Why a pool file gives no frames or fewer frames than the session says (decision 0003).
public enum MediaFault: Hashable, Sendable {
    /// `stat` gives ENOENT. `AVAudioFile` has no own code for it (probe E6a).
    case missing
    /// The file has fewer frames than its pool entry; the value is the real length (E6e).
    case short(Frames)
    /// Another type (E6h), another rate or channel count, or a read error.
    case unreadable
}

/// The fault of each pool file of the session that is not whole. With a source, only the files
/// of the clips that sound in its range on its heard tracks (decisions 0019, 0036, and 0039). It reads the disk, so never
/// call it on the main actor. Throws when the process has no free descriptor: that is not a
/// fault of a file.
public func checkMedia(
    _ session: Session, package: URL, source: ExportSource? = nil
) throws(POSIXError) -> [FileID: MediaFault] {
    try checkMedia(session, package: package, source: source, open: openMedia)
}

/// `checkMedia` with the open of each file.
func checkMedia(
    _ session: Session, package: URL, source: ExportSource?, open: MediaOpen
) throws(POSIXError) -> [FileID: MediaFault] {
    let clips = package.appending(path: clipsFolderName)
    var files = Array(session.files.values)
    if let source {
        let read = Set(
            session.heardTracks(in: source.tracks).flatMap {
                $0.clips.clips(soundingIn: source.range).map(\.file)
            })
        files = files.filter { read.contains($0.id) }
    }
    var faults: [FileID: MediaFault] = [:]
    for file in files {
        faults[file.id] = try open(file, clips, session.sampleRate).fault
    }
    return faults
}

/// What `openMedia` gives for one pool file.
typealias OpenedMedia = (file: AVAudioFile?, fault: MediaFault?, stamp: FileStamp?)

/// The type of `openMedia`, so that tests can give an open that fails.
typealias MediaOpen = @Sendable (AudioFile, URL, Int) throws(POSIXError) -> OpenedMedia

/// A point of `openMedia` where the seam of tests runs: a job of another process can rename and
/// unlink a pool file there.
enum MediaOpenStep: Hashable {
    /// `poolFileName` gave its name.
    case resolved
    /// `open(2)` gave a descriptor, and `AVAudioFile` did not open the name yet.
    case opened
}

/// Opens a pool file at the name that `poolFileName` gives (`clips` is the `Clips/` folder of the
/// package): `open(2)` with `O_NONBLOCK`, `fstat`, then `AVAudioFile`, rate, channel count,
/// length. The file is nil when it gives no frames. The fault is nil for a whole file. `open(2)`
/// tells a missing file (ENOENT) and a process with no free descriptor (EMFILE, ENFILE, thrown)
/// from the other faults; `AVAudioFile` gives neither its own code (probe E6a). An item that is
/// not a regular file is unreadable before `AVAudioFile`, which waits on a FIFO. The stamp is the
/// `fstat` of the descriptor that `open(2)` gave, nil for a fault of the open or of the kind
/// (decision 0017). A package job of another process can convert the file after the resolve, so
/// ENOENT opens the other name (WAV or FLAC) once (decision 0072). `AVAudioFile` opens the path,
/// not the descriptor: the descriptor stays open until it returns, and a failed `AVAudioFile` open
/// whose name no longer gives the device and the inode of the descriptor counts as ENOENT.
func openMedia(_ file: AudioFile, in clips: URL, rate: Int) throws(POSIXError) -> OpenedMedia {
    try openMedia(file, in: clips, rate: rate, after: { _ in })
}

/// `openMedia` with the seam of tests after each step.
func openMedia(
    _ file: AudioFile, in clips: URL, rate: Int, after: (MediaOpenStep) -> Void
) throws(POSIXError) -> OpenedMedia {
    let package = clips.deletingLastPathComponent()
    let name = poolFileName(file, in: package)
    after(.resolved)
    if let opened = try openName(package.appending(path: name.name), of: file, rate: rate, after: after) {
        return opened
    }
    let other = name.form == .flac ? file.path : archivedPath(of: file.path)
    guard let other, let opened = try openName(clips.appending(path: other), of: file, rate: rate, after: after)
    else { return (nil, .missing, nil) }
    return opened
}

/// The open of one name of `file`, or nil when the name gives no file: ENOENT, or a failed
/// `AVAudioFile` open after the name moved off the file of the descriptor.
private func openName(
    _ url: URL, of file: AudioFile, rate: Int, after: (MediaOpenStep) -> Void
) throws(POSIXError) -> OpenedMedia? {
    let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
        let code = errno
        if code == EMFILE || code == ENFILE { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EMFILE) }
        return code == ENOENT ? nil : (nil, .unreadable, nil)
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return (nil, .unreadable, nil) }
    let stamp = FileStamp(info)
    after(.opened)
    guard let audio = try? AVAudioFile(forReading: url) else {
        var now = stat()
        guard stat(url.path, &now) == 0, now.st_dev == info.st_dev, now.st_ino == info.st_ino else { return nil }
        return (nil, .unreadable, stamp)
    }
    guard audio.fileFormat.sampleRate == Double(rate), Int(audio.fileFormat.channelCount) == file.layout.channelCount
    else { return (nil, .unreadable, stamp) }
    let length = Frames(Int(audio.length))
    return (audio, length < file.length ? .short(length) : nil, stamp)
}
