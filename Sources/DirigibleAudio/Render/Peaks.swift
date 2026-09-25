import AVFoundation
import Accelerate
import DirigibleCore

/// One bin or one drawn column: linear magnitudes, 65535 = 0 dBFS.
public struct PeakColumn: Hashable, Sendable {
    public var peak: UInt16
    public var rms: UInt16

    public init(peak: UInt16, rms: UInt16) {
        self.peak = peak
        self.rms = rms
    }

    public static let zero = PeakColumn(peak: 0, rms: 0)
}

/// The size and the modification time of a WAV (probes F1 to F6). A rewrite changes it on APFS;
/// a copy and a move of the package keep it.
struct FileStamp: Hashable, Sendable {
    var size: Int64
    var seconds: Int
    var nanoseconds: Int
}

/// The peaks of one WAV (decision 0017). No public init: only the compute and the decode make one.
public struct Peaks: Hashable, Sendable {
    /// The frames per bin of each level. The upper levels come from level 0.
    static let binFrames = [256, 4096, 65536]

    /// The real length of the WAV. A short WAV has fewer frames than its pool entry.
    public let frames: Frames
    let stamp: FileStamp
    let channels: Int
    let sampleRate: Int
    let levels: [[PeakColumn]]

    /// Column i covers the file frames `from + i * step ..< from + (i + 1) * step`. It reads the
    /// largest level whose bin is at or below `step`, and takes the maximum peak and the maximum
    /// RMS of the bins that the column touches. A column at or after `frames` gets zero.
    public func fill(_ columns: inout [PeakColumn], from: Double, step: Double) {
        let level = Self.binFrames.lastIndex { Double($0) <= step } ?? 0
        let bin = Double(Self.binFrames[level])
        let bins = levels[level]
        let count = Double(bins.count)
        for index in columns.indices {
            let start = from + Double(index) * step
            var column = PeakColumn.zero
            if start < Double(frames.count) {
                let low = Int(min(max((start / bin).rounded(.down), 0), count))
                let high = Int(min(max(((start + step) / bin).rounded(.up), 0), count))
                for value in bins[low..<max(low, high)] {
                    column.peak = max(column.peak, value.peak)
                    column.rms = max(column.rms, value.rms)
                }
            }
            columns[index] = column
        }
    }
}

enum PeakPause: Sendable {
    case go
    /// The pause waited for a take: the file can have changed, so the compute starts again.
    case waited
    case stop
}

enum PeakError: Error, Equatable {
    /// The code of the read error: an errno or an OSStatus such as -40 (probe-read-error).
    case readFailed(Int)
    case restart
    case cancelled
}

/// Reads the file that `openMedia` opened, in blocks of 262,144 frames (a multiple of 256, probe
/// P1). Calls `pause` before each block: `.stop` ends the compute (`.cancelled`); `.waited` ends
/// it (`.restart`), so the pass opens the file again with a new stamp. Never on the main actor.
/// The peak of a bin is the maximum over the channels; the RMS is over all channels and frames.
func computePeaks(_ file: AVAudioFile, stamp: FileStamp, pause: () async -> PeakPause) async throws(PeakError)
    -> Peaks
{
    let block: AVAudioFrameCount = 262_144
    let channels = Int(file.processingFormat.channelCount)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block),
        let data = buffer.floatChannelData
    else { throw .readFailed(0) }
    var base = [PeakColumn](repeating: .zero, count: Int((file.length + 255) / 256))
    var bins = 0
    file.framePosition = 0
    while file.framePosition < file.length {
        switch await pause() {
        case .go: break
        case .waited: throw .restart
        case .stop: throw .cancelled
        }
        do { try file.read(into: buffer, frameCount: block) } catch { throw .readFailed((error as NSError).code) }
        let count = Int(buffer.frameLength)
        if count == 0 { break }
        // Plain loops and pointer writes: the debug build of the tests runs this per bin.
        base.withUnsafeMutableBufferPointer { out in
            var start = 0
            while start < count, bins < out.count {
                let length = vDSP_Length(count - start < 256 ? count - start : 256)
                var peak: Float = 0
                var squares: Float = 0
                var value: Float = 0
                var channel = 0
                while channel < channels {
                    vDSP_maxmgv(data[channel] + start, 1, &value, length)
                    if value > peak { peak = value }
                    vDSP_svesq(data[channel] + start, 1, &value, length)
                    squares += value
                    channel += 1
                }
                out[bins] = PeakColumn(
                    peak: quantize(peak), rms: quantize((squares / Float(Int(length) * channels)).squareRoot()))
                bins += 1
                start += 256
            }
        }
    }
    base.removeSubrange(bins...)
    return Peaks(
        frames: Frames(Int(file.framePosition)), stamp: stamp, channels: channels,
        sampleRate: Int(file.fileFormat.sampleRate),
        levels: [base, upperLevel(base, 16), upperLevel(base, 256)])
}

/// A level of `factor` base bins per bin: the maximum peak, and the root of the mean of the squares.
private func upperLevel(_ base: [PeakColumn], _ factor: Int) -> [PeakColumn] {
    var level = [PeakColumn](repeating: .zero, count: (base.count + factor - 1) / factor)
    base.withUnsafeBufferPointer { bins in
        level.withUnsafeMutableBufferPointer { out in
            var index = 0
            while index < bins.count {
                var peak: UInt16 = 0
                var squares = 0.0
                let end = index + factor < bins.count ? index + factor : bins.count
                for bin in index..<end {
                    if bins[bin].peak > peak { peak = bins[bin].peak }
                    squares += Double(bins[bin].rms) * Double(bins[bin].rms)
                }
                out[index / factor] = PeakColumn(
                    peak: peak, rms: UInt16((squares / Double(end - index)).squareRoot().rounded()))
                index = end
            }
        }
    }
    return level
}

private func quantize(_ value: Float) -> UInt16 { value >= 1 ? 65535 : UInt16((value * 65535).rounded()) }
