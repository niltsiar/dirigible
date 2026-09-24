import Foundation

/// Interleaved sine samples with amplitude 0.5. Channel `c` has the frequency
/// `frequency * (c + 1)`, so a test can tell the channels apart.
func sine(seconds: Double, rate: Double, channels: Int = 1, frequency: Double = 1000) -> [Float] {
    let frames = Int((seconds * rate).rounded())
    var samples = [Float](repeating: 0, count: frames * channels)
    for frame in 0..<frames {
        for channel in 0..<channels {
            let phase = 2 * Double.pi * frequency * Double(channel + 1) * Double(frame) / rate
            samples[frame * channels + channel] = Float(0.5 * sin(phase))
        }
    }
    return samples
}

/// A unique temporary folder, removed at deinit.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "DirigibleAudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// SplitMix64: a small seeded generator, so a random test gives the same values on each run.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
