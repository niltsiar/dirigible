import AVFoundation
import Accelerate
import DirigibleCore

/// Renders the mix of a session (decision 0016): stereo float32, non-interleaved, at the session
/// rate. Clip gain plus track gain in dB is one linear factor. A mono clip goes to both channels,
/// a stereo clip left to left and right to right (0007). Where no clip or no media is, the mix is
/// silence. One owner, not Sendable: the Player or the command-line render. It opens each file at
/// most once, and each read stops at the real length of the file (probe E6c).
final class MixReader {
    var session: Session
    /// The faults of the files that this reader opened or read.
    private(set) var faults: [FileID: MediaFault] = [:]
    private let clips: URL
    /// The open files. Nil for a file that did not open.
    private var files: [FileID: AVAudioFile?] = [:]
    private var scratch: [AVAudioFormat: AVAudioPCMBuffer] = [:]

    init(package: URL, session: Session) {
        self.session = session
        clips = package.appending(path: clipsFolderName)
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
        if let file = files[id] { return file }
        guard let entry = session.files[id] else { return nil }
        let (file, fault) = openMedia(entry, in: clips, rate: session.sampleRate)
        files[id] = file
        faults[id] = fault
        return file
    }
}
