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

/// The fault of each pool file of the session that is not whole. It reads the disk, so never
/// call it on the main actor.
public func checkMedia(_ session: Session, package: URL) -> [FileID: MediaFault] {
    let clips = package.appending(path: clipsFolderName)
    var faults: [FileID: MediaFault] = [:]
    for file in session.files.values {
        faults[file.id] = openMedia(file, in: clips, rate: session.sampleRate).fault
    }
    return faults
}

/// Opens a pool file: `stat`, open, rate, channel count, length. The file is nil when it gives
/// no frames. The fault is nil for a whole file.
func openMedia(_ file: AudioFile, in clips: URL, rate: Int) -> (file: AVAudioFile?, fault: MediaFault?) {
    let url = clips.appending(path: file.path)
    var status = stat()
    guard stat(url.path, &status) == 0 else { return (nil, errno == ENOENT ? .missing : .unreadable) }
    guard let audio = try? AVAudioFile(forReading: url), audio.fileFormat.sampleRate == Double(rate),
        Int(audio.fileFormat.channelCount) == file.layout.channelCount
    else { return (nil, .unreadable) }
    let length = Frames(Int(audio.length))
    return (audio, length < file.length ? .short(length) : nil)
}
