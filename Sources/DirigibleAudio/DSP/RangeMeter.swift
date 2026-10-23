import AVFoundation
import Accelerate
import DirigibleCore

/// The values of `meter` for one range of the heard stereo mix (decision 0062). A value with no
/// data is nil: under 400 ms `maxMomentary`, under 3 s `maxShortTerm` and `loudnessRange`, and
/// for digital silence each loudness value and both peaks.
public struct MixMeasure: Hashable, Sendable {
    /// The gated integrated loudness of BS.1770-5.
    public let integrated: LUFS?
    /// The loudness range of EBU Tech 3342 in LU.
    public let loudnessRange: Double?
    /// The loudest 400 ms block.
    public let maxMomentary: LUFS?
    /// The loudest 3 s window, one each 100 ms.
    public let maxShortTerm: LUFS?
    /// The true peak of BS.1770-5 Annex 2 in dBTP.
    public let truePeak: Double?
    /// The largest absolute sample in dBFS. A mix over full scale gives a value over 0.
    public let samplePeak: Double?
}

/// A streaming meter of the values of `MixMeasure` for stereo audio at one rate. It works in
/// memory only.
struct RangeMeter: Sendable {
    /// The gates of the loudness range (EBU Tech 3342): absolute -70 LUFS, relative -20 LU.
    static let rangeAbsoluteGate = -70.0
    static let rangeRelativeGate = -20.0

    /// Nil at a rate that the K-weighting does not support: then each loudness value is nil.
    private var loudness: LoudnessMeter?
    private var truePeak = TruePeakMeter(layout: .stereo)
    private var peak: Float = 0

    init(sampleRate: Int) {
        loudness = LoudnessMeter(sampleRate: sampleRate, layout: .stereo, keepsShortTerms: true)
    }

    /// Adds the frames of `buffer`: deinterleaved stereo Float32 at the meter rate.
    mutating func feed(_ buffer: AVAudioPCMBuffer) {
        loudness?.feed(buffer)
        truePeak.feed(buffer)
        guard let data = buffer.floatChannelData else { return }
        for channel in 0..<2 {
            var largest: Float = 0
            vDSP_maxmgv(data[channel], 1, &largest, vDSP_Length(buffer.frameLength))
            peak = max(peak, largest)
        }
    }

    func result() -> MixMeasure {
        let result = loudness?.result()
        let shortTerms = loudness.map { $0.nonFinite ? [] : $0.shortTerms ?? [] } ?? []
        func level(_ meanSquare: Double?) -> LUFS? {
            meanSquare.flatMap { $0 > 0 ? LUFS(value: Loudness.lufs($0)) : nil }
        }
        return MixMeasure(
            integrated: result?.integrated, loudnessRange: Self.range(of: shortTerms),
            maxMomentary: level(result?.blocks.max()), maxShortTerm: level(shortTerms.max()),
            truePeak: truePeak.result(), samplePeak: peak > 0 ? 20 * log10(Double(peak)) : nil)
    }

    /// The loudness range of the short-term mean squares (EBU Tech 3342 and its MATLAB code): the
    /// values at or over -70 LUFS, then those at or over 20 LU under their power mean; P95 - P10,
    /// with Pp the sorted value at index round((n - 1) p / 100 + 1), 1-based. Nil when no value
    /// passes the gates.
    static func range(of shortTerms: [Double]) -> Double? {
        let absolute = shortTerms.filter { $0 >= Loudness.meanSquare(rangeAbsoluteGate) }
        guard !absolute.isEmpty else { return nil }
        let relative = absolute.reduce(0, +) / Double(absolute.count) * pow(10, rangeRelativeGate / 10)
        let gated = absolute.filter { $0 >= relative }.sorted()
        func percentile(_ p: Double) -> Double {
            Loudness.lufs(gated[Int((Double(gated.count - 1) * p / 100 + 1).rounded()) - 1])
        }
        return percentile(95) - percentile(10)
    }
}
