import AVFoundation
import Accelerate
import DirigibleCore

/// The 4x oversampling FIR of ITU-R BS.1770-5 Annex 2: 4 phases of 12 taps. It keeps the last
/// 11 frames of each channel, so a window can cross a feed edge. It uses 4x at every rate.
struct TruePeakFilter: Sendable {
    /// Phase 3 is phase 0 reversed and phase 2 is phase 1 reversed. So the correlation of
    /// `vDSP_conv` gives the same four outputs as the convolution of the standard.
    static let phases: [[Float]] = [
        [
            0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625,
            0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500,
        ],
        [
            -0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250,
            0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375,
        ],
        [
            -0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500,
            0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875,
        ],
        [
            -0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500,
            0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750,
        ],
    ]
    static let taps = 12
    /// The frames before the newest frame that a window holds.
    static let history = taps - 1

    /// Per channel: the last 11 frames of the feed before, then the frames of this feed.
    private var work: [[Float]]
    private var scratch: [Float] = []

    init(channels: Int) {
        work = Array(repeating: [Float](repeating: 0, count: Self.history), count: channels)
    }

    /// Sets `detector[n]` for each frame n of `buffer`: the largest of |sample| and |each phase
    /// output| of the 12-frame window that ends at frame n, over all channels. It grows
    /// `detector` to the frame count and leaves the values after it.
    /// Precondition: deinterleaved Float32 with the channel count of the filter.
    mutating func peaks(_ buffer: AVAudioPCMBuffer, into detector: inout [Float]) {
        precondition(
            buffer.format.commonFormat == .pcmFormatFloat32 && !buffer.format.isInterleaved
                && Int(buffer.format.channelCount) == work.count,
            "the true-peak filter takes deinterleaved Float32 with its channel count")
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return }
        let count = vDSP_Length(frames)
        if detector.count < frames { detector += repeatElement(0, count: frames - detector.count) }
        if scratch.count < frames { scratch += repeatElement(0, count: frames - scratch.count) }
        for channel in work.indices {
            if work[channel].count < Self.history + frames {
                work[channel] += repeatElement(0, count: Self.history + frames - work[channel].count)
            }
            let samples = data[channel]
            work[channel].withUnsafeMutableBufferPointer { window in
                let base = window.baseAddress!
                (base + Self.history).update(from: samples, count: frames)
                scratch.withUnsafeMutableBufferPointer { phase in
                    detector.withUnsafeMutableBufferPointer { peak in
                        if channel == 0 {
                            vDSP_vabs(samples, 1, peak.baseAddress!, 1, count)
                        } else {
                            vDSP_vmaxmg(samples, 1, peak.baseAddress!, 1, peak.baseAddress!, 1, count)
                        }
                        for taps in Self.phases {
                            vDSP_conv(base, 1, taps, 1, phase.baseAddress!, 1, count, vDSP_Length(Self.taps))
                            vDSP_vmaxmg(phase.baseAddress!, 1, peak.baseAddress!, 1, peak.baseAddress!, 1, count)
                        }
                    }
                }
                // The regions overlap when the feed has fewer than 11 frames.
                memmove(base, base + frames, Self.history * MemoryLayout<Float>.stride)
            }
        }
    }
}

/// The largest true peak of one signal (BS.1770-5 Annex 2). It works in memory only.
struct TruePeakMeter: Sendable {
    private var filter: TruePeakFilter
    private var detector: [Float] = []
    private var maximum: Float = 0

    init(layout: ChannelLayout) { filter = TruePeakFilter(channels: layout.channelCount) }

    /// Adds the frames of `buffer`. Any block size works.
    mutating func feed(_ buffer: AVAudioPCMBuffer) {
        filter.peaks(buffer, into: &detector)
        var peak: Float = 0
        vDSP_maxv(detector, 1, &peak, vDSP_Length(buffer.frameLength))
        maximum = max(maximum, peak)
    }

    /// The true peak in dBTP. Nil for digital silence.
    func result() -> Double? { maximum > 0 ? 20 * log10(Double(maximum)) : nil }
}
