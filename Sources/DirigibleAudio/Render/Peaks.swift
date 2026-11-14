import AVFoundation
import Accelerate
import DirigibleCore

/// One bin or one drawn column: linear magnitudes, `UInt32.max` = 0 dBFS. The lowest step is
/// -192.7 dBFS, so a 24-bit signal keeps its level down to its last bit.
public struct PeakColumn: Hashable, Sendable {
    public var peak: UInt32
    public var rms: UInt32

    public init(peak32 peak: UInt32, rms32 rms: UInt32) {
        self.peak = peak
        self.rms = rms
    }

    /// Magnitudes of 16 bits, 65535 = 0 dBFS. A value v becomes v x 65537, the same level:
    /// 65535 x 65537 = `UInt32.max`.
    public init(peak: UInt16, rms: UInt16) {
        self.init(peak32: UInt32(peak) * 65537, rms32: UInt32(rms) * 65537)
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
        fillColumns(
            &columns, from: from, step: step, bins: levels[level], bin: Double(Self.binFrames[level]),
            end: Double(frames.count))
    }
}

/// The column loop of `Peaks.fill` and `LivePeaks.fill`. Column i covers the frames
/// `from + i * step ..< from + (i + 1) * step` and takes the maximum peak and the maximum RMS of
/// the bins of `bin` frames that it touches. A column at or after `end` gets zero.
func fillColumns(
    _ columns: inout [PeakColumn], from: Double, step: Double, bins: [PeakColumn], bin: Double, end: Double
) {
    // Plain loops and pointers: the renderer calls this for each drawn column, also in the
    // debug build of the tests.
    bins.withUnsafeBufferPointer { bins in
        let count = Double(bins.count)
        columns.withUnsafeMutableBufferPointer { out in
            var index = 0
            while index < out.count {
                let start = from + Double(index) * step
                var column = PeakColumn.zero
                if start < end {
                    let low = (start / bin).rounded(.down)
                    let high = ((start + step) / bin).rounded(.up)
                    var bin = low < 0 ? 0 : Int(low < count ? low : count)
                    let last = high < 0 ? 0 : Int(high < count ? high : count)
                    while bin < last {
                        if bins[bin].peak > column.peak { column.peak = bins[bin].peak }
                        if bins[bin].rms > column.rms { column.rms = bins[bin].rms }
                        bin += 1
                    }
                }
                out[index] = column
                index += 1
            }
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
/// it (`.restart`), so the pass opens the file again with a new stamp. Calls `afterRead` after
/// each block read, on the thread of the read. Never on the main actor.
/// The peak of a bin is the maximum over the channels; the RMS is over all channels and frames.
func computePeaks(
    _ file: AVAudioFile, stamp: FileStamp, afterRead: () -> Void = {}, pause: () async -> PeakPause
) async throws(PeakError)
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
        afterRead()
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
                    peak32: quantize(peak), rms32: quantize((squares / Float(Int(length) * channels)).squareRoot()))
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
                var peak: UInt32 = 0
                var squares = 0.0
                let end = index + factor < bins.count ? index + factor : bins.count
                for bin in index..<end {
                    if bins[bin].peak > peak { peak = bins[bin].peak }
                    squares += Double(bins[bin].rms) * Double(bins[bin].rms)
                }
                out[index / factor] = PeakColumn(
                    peak32: peak, rms32: UInt32((squares / Double(end - index)).squareRoot().rounded()))
                index = end
            }
        }
    }
    return level
}

/// A linear magnitude as a `PeakColumn` value: `UInt32.max` = 0 dBFS. The product is a `Double`,
/// because a `Float` cannot hold 2^32 - 1.
func quantize(_ value: Float) -> UInt32 { value >= 1 ? .max : UInt32((Double(value) * Double(UInt32.max)).rounded()) }
