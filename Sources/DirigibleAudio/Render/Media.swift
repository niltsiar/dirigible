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
/// of the clips that overlap its range on its tracks (decision 0019). It reads the disk, so never
/// call it on the main actor. Throws when the process has no free descriptor: that is not a
/// fault of a file.
public func checkMedia(
    _ session: Session, package: URL, source: ExportSource? = nil
) throws(POSIXError) -> [FileID: MediaFault] {
    let clips = package.appending(path: clipsFolderName)
    var files = Array(session.files.values)
    if let source {
        let read = Set(
            session.tracks.filter { source.tracks?.contains($0.id) ?? true }.flatMap {
                $0.clips.clips(overlapping: source.range).map(\.file)
            })
        files = files.filter { read.contains($0.id) }
    }
    var faults: [FileID: MediaFault] = [:]
    for file in files {
        faults[file.id] = try openMedia(file, in: clips, rate: session.sampleRate).fault
    }
    return faults
}

/// The type of `openMedia`, so that tests can give an open that fails.
typealias MediaOpen =
    @Sendable (AudioFile, URL, Int) throws(POSIXError) -> (
        file: AVAudioFile?, fault: MediaFault?, stamp: FileStamp?
    )

/// Opens a pool file: `open(2)`, then `AVAudioFile`, rate, channel count, length. The file is
/// nil when it gives no frames. The fault is nil for a whole file. `open(2)` tells a missing
/// file (ENOENT) and a process with no free descriptor (EMFILE, ENFILE, thrown) from the other
/// faults; `AVAudioFile` gives neither its own code (probe E6a). The stamp is the `fstat` of the
/// descriptor that `open(2)` gave, nil when it failed (decision 0017).
func openMedia(_ file: AudioFile, in clips: URL, rate: Int) throws(POSIXError) -> (
    file: AVAudioFile?, fault: MediaFault?, stamp: FileStamp?
) {
    let url = clips.appending(path: file.path)
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
        let code = errno
        if code == EMFILE || code == ENFILE { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EMFILE) }
        return (nil, code == ENOENT ? .missing : .unreadable, nil)
    }
    var info = stat()
    let stamp =
        fstat(descriptor, &info) == 0
        ? FileStamp(
            size: Int64(info.st_size), seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec) : nil
    close(descriptor)
    guard let audio = try? AVAudioFile(forReading: url), audio.fileFormat.sampleRate == Double(rate),
        Int(audio.fileFormat.channelCount) == file.layout.channelCount
    else { return (nil, .unreadable, stamp) }
    let length = Frames(Int(audio.length))
    return (audio, length < file.length ? .short(length) : nil, stamp)
}
