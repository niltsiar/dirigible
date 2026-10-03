import AVFoundation
import DirigibleCore

/// The values of the live loudness meter (decision 0033). Each value is nil until its window
/// fills, and nil for silence.
public struct LoudnessValues: Hashable, Sendable {
    /// The last 400 ms.
    public var momentary: LUFS?
    /// The last 3 s.
    public var shortTerm: LUFS?
    /// The gated loudness since the reset.
    public var integrated: LUFS?
    /// The largest true peak since the reset, in dBTP.
    public var truePeak: Double?
    /// The measured duration since the reset.
    public var seconds: Double

    public static let none = LoudnessValues(momentary: nil, shortTerm: nil, integrated: nil, truePeak: nil, seconds: 0)

    public init(momentary: LUFS?, shortTerm: LUFS?, integrated: LUFS?, truePeak: Double?, seconds: Double) {
        self.momentary = momentary
        self.shortTerm = shortTerm
        self.integrated = integrated
        self.truePeak = truePeak
        self.seconds = seconds
    }
}

/// The loudness meter of a play: momentary, short-term, integrated, and true peak of one signal.
/// It computes the integrated value once per new block, so `values` does no work.
struct LiveLoudness: Sendable {
    /// Internal, so the benchmark can set 2 h of blocks.
    var meter: LoudnessMeter
    private var peak: TruePeakMeter
    /// The meters with no frames, for `reset()`.
    private let empty: (meter: LoudnessMeter, peak: TruePeakMeter)
    private var frames = 0
    private(set) var values = LoudnessValues.none

    /// Nil when `LoudnessMeter` refuses the rate (3 363 Hz or less).
    init?(sampleRate: Int, layout: ChannelLayout) {
        guard let meter = LoudnessMeter(sampleRate: sampleRate, layout: layout) else { return nil }
        self.meter = meter
        peak = TruePeakMeter(layout: layout)
        empty = (meter, peak)
    }

    /// Adds the frames of `buffer`. Any block size works.
    /// Precondition: deinterleaved Float32 at the meter rate, with the channel count of the layout.
    mutating func feed(_ buffer: AVAudioPCMBuffer) {
        let blocks = meter.blocks.count
        meter.feed(buffer)
        peak.feed(buffer)
        frames += Int(buffer.frameLength)
        if meter.blocks.count != blocks { values.integrated = meter.result().integrated }
        values.momentary = meter.momentary
        values.shortTerm = meter.shortTerm
        values.truePeak = peak.result()
        values.seconds = Double(frames) / Double(meter.sampleRate)
    }

    /// Starts again with no frames: a play from a new frame.
    mutating func reset() {
        (meter, peak) = empty
        frames = 0
        values = .none
    }
}
