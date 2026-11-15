import DirigibleCore
import Foundation

@testable import DirigibleAudio

extension PeakColumn {
    /// Magnitudes of 16 bits, 65535 = 0 dBFS. A value v becomes v x 65537, the same level:
    /// 65535 x 65537 = `UInt32.max`.
    init(peak16: UInt16, rms16: UInt16) { self.init(peak: UInt32(peak16) * 65537, rms: UInt32(rms16) * 65537) }
}

/// The peaks of a mono file of `frames` frames at 48 kHz: random peaks (the same on each run), and
/// a random RMS at or under each peak, at the levels of 256, 4,096, and 65,536 frames per column.
/// A peak is a random UInt32 shifted right by 0 to 31 bits, so each level from 0 dBFS down to the
/// lowest step occurs, not only the top 96 dB of a uniform draw.
func randomPeaks(frames: Int) -> Peaks {
    var random = SplitMix(seed: 9)
    return assemblePeaks(frames: frames) {
        let peak = UInt32.random(in: 0...UInt32.max, using: &random) >> UInt32.random(in: 0...31, using: &random)
        return PeakColumn(peak: peak, rms: UInt32.random(in: 0...peak, using: &random))
    }
}

/// The peaks of the benches: a uniform 16-bit draw with the RMS at half the peak. This input stays
/// the same across commits, so the times of the benches compare.
func benchPeaks(frames: Int) -> Peaks {
    var random = SplitMix(seed: 9)
    return assemblePeaks(frames: frames) {
        let peak = UInt16.random(in: 0...65535, using: &random)
        return PeakColumn(peak16: peak, rms16: peak / 2)
    }
}

/// The peaks of a mono file of `frames` frames at 48 kHz, with each base column from `column`, at the
/// levels of 256, 4,096, and 65,536 frames per column.
private func assemblePeaks(frames: Int, column: () -> PeakColumn) -> Peaks {
    let base = (0..<(frames / 256)).map { _ in column() }
    func upper(_ factor: Int) -> [PeakColumn] {
        stride(from: 0, to: base.count, by: factor).map { start in
            let bins = base[start..<min(start + factor, base.count)]
            return PeakColumn(peak: bins.map(\.peak).max()!, rms: bins.map(\.rms).max()!)
        }
    }
    return Peaks(
        frames: Frames(frames), stamp: FileStamp(size: 0, seconds: 0, nanoseconds: 0), channels: 1,
        sampleRate: 48_000, levels: [base, upper(16), upper(256)])
}
