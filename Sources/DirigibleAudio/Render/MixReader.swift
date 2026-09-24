import AVFoundation
import Accelerate
import DirigibleCore

/// Renders the mix of a session (decision 0016): stereo float32, non-interleaved, at the session
/// rate. A mono clip goes to both channels at unity. Where no clip is, the mix is silence. One
/// owner, not Sendable: the Player or the command-line render. It opens each file at most once.
final class MixReader {
    var session: Session
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
                let target = part.lowerBound.count - range.lowerBound.count
                let frames = vDSP_Length(read.frameLength)
                let source = read.floatChannelData![0]
                for channel in 0..<2 {
                    let destination = out[channel] + target
                    vDSP_vadd(source, 1, destination, 1, destination, 1, frames)
                }
            }
        }
    }

    /// The frames of `file` from `start` for the length of `part`, or nil when the file gives none.
    private func read(_ id: FileID, from start: Frames, _ part: Range<Frames>) -> AVAudioPCMBuffer? {
        guard let file = open(id) else { return nil }
        let count = AVAudioFrameCount(part.upperBound.count - part.lowerBound.count)
        let format = file.processingFormat
        if scratch[format].map({ $0.frameCapacity < count }) ?? true {
            scratch[format] = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)
        }
        guard let buffer = scratch[format] else { return nil }
        file.framePosition = AVAudioFramePosition(start.count)
        guard (try? file.read(into: buffer, frameCount: count)) != nil else { return nil }
        return buffer
    }

    private func open(_ id: FileID) -> AVAudioFile? {
        if let file = files[id] { return file }
        let file = session.files[id].flatMap { try? AVAudioFile(forReading: clips.appending(path: $0.path)) }
        files[id] = file
        return file
    }
}
