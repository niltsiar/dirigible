import AVFoundation
import Accelerate
import DirigibleCore

/// Renders the mix of a session (decision 0016): stereo float32, non-interleaved, at the session
/// rate. Clip gain plus track gain in dB is one linear factor, times the fade factor of decision
/// 0035 of the sounding clip of the lane, whose fades hold its crossfades with the curve of each
/// edge (decision 0036), times the gain envelope factor of the clip (decision 0060). A mono clip
/// goes to both channels, a stereo clip left to left and right to right (0007). It reads only the
/// heard tracks of its track set: muted and unsoloed tracks are out (decision 0039). Where no clip
/// or no media is, the mix is silence. One owner, not Sendable: the Player or the command-line
/// render. It keeps at most `openLimit` files open and closes the least recently used one, so a
/// session with many files does not use up the descriptors of the process. Each read stops at the
/// real length of the file (probe E6c).
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
    /// The track set of the mix. Nil: every track. `Session.heardTracks(in:)` then leaves out the
    /// tracks that are not heard.
    let tracks: Set<TrackID>?
    /// The open files, the most recently used last.
    private var files: [(id: FileID, file: AVAudioFile)] = []
    /// The files that did not open. They hold no descriptor.
    private var failed: Set<FileID> = []
    private var scratch: [AVAudioFormat: AVAudioPCMBuffer] = [:]
    /// The gain factors of one clip part, and the fade factors of a part with a gain envelope and a
    /// fade. Each grows only for a longer part.
    private var factors: [Float] = []
    private var fadeFactors: [Float] = []
    #if DEBUG
        /// The clip parts that read the gain envelope.
        private(set) var envelopeParts = 0
    #endif
    /// Opens a pool file. Tests give one that throws EMFILE.
    private let openFile: MediaOpen

    init(package: URL, session: Session, tracks: Set<TrackID>? = nil, open: @escaping MediaOpen = openMedia) {
        self.session = session
        self.package = package
        self.tracks = tracks
        openFile = open
    }

    /// Sets `buffer.frameLength` to the range length. `buffer` is stereo float32 and holds the range.
    func render(_ range: Range<Frames>, into buffer: AVAudioPCMBuffer) {
        let count = range.upperBound.count - range.lowerBound.count
        buffer.frameLength = AVAudioFrameCount(count)
        let out = buffer.floatChannelData!
        for channel in 0..<2 { out[channel].update(repeating: 0, count: count) }
        for track in session.heardTracks(in: tracks) {
            for sounding in track.clips.sounding(in: range) {
                let clip = sounding.clip
                let part = max(clip.start, range.lowerBound)..<min(clip.end, range.upperBound)
                guard let read = read(clip.file, from: clip.offset + (part.lowerBound - clip.start), part) else {
                    continue
                }
                let decibels = clip.gain.dB + track.gain.dB
                var gain = Float(pow(10, decibels / 20))
                let target = part.lowerBound.count - range.lowerBound.count
                let count = Int(read.frameLength)
                let frames = vDSP_Length(count)
                let last = Int(read.format.channelCount) - 1
                // The clip frame of the part start. A part with no frame in a fade and no envelope
                // point keeps the one-gain path.
                let first = part.lowerBound - clip.start
                let faded = clip.fades.fadeIn > first || clip.fades.fadeOut > clip.length - first - Frames(count)
                let enveloped = !clip.envelope.isEmpty
                if faded || enveloped {
                    if factors.count < count { factors = [Float](repeating: 0, count: count) }
                    if faded, enveloped, fadeFactors.count < count { fadeFactors = [Float](repeating: 0, count: count) }
                    factors.withUnsafeMutableBufferPointer { all in
                        let factors = UnsafeMutableBufferPointer(rebasing: all[..<count])
                        guard enveloped else {
                            gainFactors(
                                clip.fades, curves: sounding.curves, length: clip.length, from: first, gain: gain,
                                into: factors)
                            return
                        }
                        #if DEBUG
                            envelopeParts += 1
                        #endif
                        envelopeFactors(clip.envelope, from: clip.offset + first, decibels: decibels, into: factors)
                        guard faded else { return }
                        fadeFactors.withUnsafeMutableBufferPointer { all in
                            let fades = UnsafeMutableBufferPointer(rebasing: all[..<count])
                            gainFactors(
                                clip.fades, curves: sounding.curves, length: clip.length, from: first, gain: 1,
                                into: fades)
                            vDSP_vmul(factors.baseAddress!, 1, fades.baseAddress!, 1, factors.baseAddress!, 1, frames)
                        }
                    }
                }
                for channel in 0..<2 {
                    let source = read.floatChannelData![min(channel, last)]
                    let destination = out[channel] + target
                    if faded || enveloped {
                        vDSP_vma(source, 1, factors, 1, destination, 1, destination, 1, frames)
                    } else {
                        vDSP_vsma(source, 1, &gain, destination, 1, destination, 1, frames)
                    }
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
            let (file, fault, _) = try openFile(
                entry, package.appending(path: clipsFolderName), session.sampleRate)
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

/// Fills `factors` with `gain` times the fade factor of the clip frames `from ..< from +
/// factors.count` of a clip of `length` frames, with the curve of each edge (decisions 0035 and
/// 0036). In each fade it ramps the frame index from an `Int` start, then scales it, so no clip
/// frame above 2^24 becomes a Float (probe B1: 1.3e-7 or less). A frame is in at most one fade,
/// because fadeIn + fadeOut <= length.
func gainFactors(
    _ fades: Fades, curves: Fades.Curves, length: Frames, from: Frames, gain: Float,
    into factors: UnsafeMutableBufferPointer<Float>
) {
    guard let base = factors.baseAddress else { return }
    var level = gain
    vDSP_vfill(&level, base, 1, vDSP_Length(factors.count))
    let end = from.count + factors.count
    // The fade-in: index k for the frames from ..< I.
    let inEnd = min(end, fades.fadeIn.count)
    if from.count < inEnd {
        fadeRamp(
            base, count: inEnd - from.count, start: from.count, step: 1, fade: fades.fadeIn, curve: curves.start,
            gain: gain)
    }
    // The fade-out: index N - k, from O down to 1, for the frames N - O ..< N.
    let outStart = max(from.count, length.count - fades.fadeOut.count)
    if outStart < end {
        fadeRamp(
            base + (outStart - from.count), count: end - outStart, start: length.count - outStart, step: -1,
            fade: fades.fadeOut, curve: curves.end, gain: gain)
    }
}

/// Writes gain * sin(pi/2 * index / fade), or gain * index / fade with the linear curve, for
/// index = start, start + step, and so on.
private func fadeRamp(
    _ out: UnsafeMutablePointer<Float>, count: Int, start: Int, step: Float, fade: Frames, curve: Fades.Curve,
    gain: Float
) {
    var (first, step, gain) = (Float(start), step, gain)
    let frames = vDSP_Length(count)
    vDSP_vramp(&first, &step, out, 1, frames)
    switch curve {
    case .sine:
        var scale = Float(Double.pi / 2 / Double(fade.count))
        vDSP_vsmul(out, 1, &scale, out, 1, frames)
        vvsinf(out, out, [Int32(count)])
        vDSP_vsmul(out, 1, &gain, out, 1, frames)
    case .linear:
        var scale = Float(Double(gain) / Double(fade.count))
        vDSP_vsmul(out, 1, &scale, out, 1, frames)
    }
}

/// Fills `factors` with 10^((`decibels` + g) / 20), g the dB of `envelope`, which has a point, at the
/// file frames `from ..< from + factors.count` (decision 0060). In each run of frames between two points, it computes
/// the dB of the run start in Double and ramps the index from the run start, so no file frame
/// becomes a Float. Then one `vvexpf` takes all frames.
func envelopeFactors(
    _ envelope: GainEnvelope, from: Frames, decibels: Double, into factors: UnsafeMutableBufferPointer<Float>
) {
    guard let base = factors.baseAddress else { return }
    let (points, start, count) = (envelope.points, from.count, factors.count)
    // 10^(dB / 20) is e^(dB x ln(10) / 20).
    let scale = log(10.0) / 20
    // The first point after the part start, by binary search.
    var (next, high) = (0, points.count)
    while next < high {
        let middle = (next + high) / 2
        if points[middle].frame.count <= start { next = middle + 1 } else { high = middle }
    }
    var done = 0
    while done < count {
        let frame = start + done
        let end = next < points.count ? min(count, points[next].frame.count - start) : count
        let frames = vDSP_Length(end - done)
        if next == 0 || next == points.count {
            // Before the first point or after the last point, the gain holds.
            var level = Float((decibels + points[max(next - 1, 0)].gain.dB) * scale)
            vDSP_vfill(&level, base + done, 1, frames)
        } else {
            let (a, b) = (points[next - 1], points[next])
            let slope = (b.gain.dB - a.gain.dB) / Double((b.frame - a.frame).count)
            var (zero, one) = (Float(0), Float(1))
            var step = Float(slope * scale)
            var level = Float((decibels + a.gain.dB + slope * Double(frame - a.frame.count)) * scale)
            vDSP_vramp(&zero, &one, base + done, 1, frames)
            vDSP_vsmsa(base + done, 1, &step, &level, base + done, 1, frames)
        }
        done = end
        next += 1
    }
    var length = Int32(count)
    vvexpf(base, base, &length)
}
