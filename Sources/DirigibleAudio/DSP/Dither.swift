import AVFoundation

/// TPDF dither of ±1 LSB of 16 bit for a WAV 16 or FLAC 16 export (decision 0032): the
/// difference of two uniform values, added before the converter rounds. Each channel has its own
/// SplitMix64 stream with a fixed seed, so each export of the same mix gives the same file, and
/// FLAC equals WAV bit for bit.
struct TPDFDither: Sendable {
    private var states: [UInt64]

    init(channels: Int) { states = (0..<channels).map { 0x5EED_D17E &+ UInt64($0) } }

    /// Adds the dither to the frames of `buffer` in place.
    mutating func apply(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        for channel in states.indices {
            var state = states[channel]
            let samples = data[channel]
            for index in 0..<Int(buffer.frameLength) {
                state &+= 0x9E37_79B9_7F4A_7C15
                var value = state
                value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
                value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
                value ^= value >> 31
                // Two 32-bit uniform values; their difference is in (-1, 1) LSB of 16 bit.
                let difference = Double(value >> 32) - Double(value & 0xFFFF_FFFF)
                samples[index] += Float(difference * 0x1p-32 / 32_768)
            }
            states[channel] = state
        }
    }
}
