import AVFoundation
import Accelerate
import DirigibleCore

/// Renders the mix of a session (decision 0016): stereo float32, non-interleaved, at the session
/// rate. Clip gain plus track gain in dB is one linear factor. A mono clip goes to both channels,
/// a stereo clip left to left and right to right (0007). Where no clip or no media is, the mix is
/// silence. One owner, not Sendable: the Player or the command-line render. It keeps at most
/// `openLimit` files open and closes the least recently used one, so a session with many files
/// does not use up the descriptors of the process. Each read stops at the real length of the file
/// (probe E6c).
final class MixReader {
    /// A calibration knob: the process limit is 256 descriptors by default.
    static let openLimit = 32

    var session: Session
    /// The faults of the files that this reader opened or read.
    private(set) var faults: [FileID: MediaFault] = [:]
    /// The last open that failed because the process had no free descriptor. The mix of that
    /// file is silence, so a render must fail.
    private(set) var openError: POSIXError?
    /// The package path. The Player sets it to the path that the lock holds at each refill.
    var package: URL
    /// The open files, the most recently used last.
    private var files: [(id: FileID, file: AVAudioFile)] = []
    /// The files that did not open. They hold no descriptor.
    private var failed: Set<FileID> = []
    private var scratch: [AVAudioFormat: AVAudioPCMBuffer] = [:]

    init(package: URL, session: Session) {
        self.session = session
        self.package = package
    }

    /// Sets `buffer.frameLength` to the range length. `buffer` is stereo float32 and holds the range.
    func render(_ range: Range<Frames>, into buffer: AVAudioPCMBuffer) {
        let count = range.upperBound.count - range.lowerBound.count
        buffer.frameLength = AVAudioFrameCount(count)
        let out = buffer.floatChannelData!
        for channel in 0..<2 { out[channel].update(repeating: 0, count: count) }
        for track in session.tracks {
            for clip in track.clips.clips(overlapping: range) {
                let part = max(clip.start, range.lowerBound)..<min(clip.end, range.upperBound)
                guard let read = read(clip.file, from: clip.offset + (part.lowerBound - clip.start), part) else {
                    continue
                }
                var gain = Float(pow(10, (clip.gain.dB + track.gain.dB) / 20))
                let target = part.lowerBound.count - range.lowerBound.count
                let frames = vDSP_Length(read.frameLength)
                let last = Int(read.format.channelCount) - 1
                for channel in 0..<2 {
                    let source = read.floatChannelData![min(channel, last)]
                    let destination = out[channel] + target
                    vDSP_vsma(source, 1, &gain, destination, 1, destination, 1, frames)
                }
            }
        }
    }

    /// The frames of `file` from `start` for the length of `part`, up to the real end of the file.
    /// Nil when the file gives none; a read error marks the file `.unreadable`.
    private func read(_ id: FileID, from start: Frames, _ part: Range<Frames>) -> AVAudioPCMBuffer? {
        guard let file = open(id) else { return nil }
        let available = Int(file.length) - start.count
        guard available > 0 else { return nil }
        let count = AVAudioFrameCount(min(part.upperBound.count - part.lowerBound.count, available))
        let format = file.processingFormat
        if scratch[format].map({ $0.frameCapacity < count }) ?? true {
            scratch[format] = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)
        }
        guard let buffer = scratch[format] else { return nil }
        do {
            file.framePosition = AVAudioFramePosition(start.count)
            try file.read(into: buffer, frameCount: count)
            return buffer
        } catch {
            faults[id] = .unreadable
            return nil
        }
    }

    private func open(_ id: FileID) -> AVAudioFile? {
        if let index = files.firstIndex(where: { $0.id == id }) {
            let entry = files.remove(at: index)
            files.append(entry)
            return entry.file
        }
        guard !failed.contains(id), let entry = session.files[id] else { return nil }
        do {
            let (file, fault) = try openMedia(
                entry, in: package.appending(path: clipsFolderName), rate: session.sampleRate)
            faults[id] = fault
            guard let file else {
                failed.insert(id)
                return nil
            }
            if files.count == Self.openLimit { files.removeFirst() }
            files.append((id, file))
            return file
        } catch {
            openError = error
            return nil
        }
    }
}
