import Foundation

/// The 25 one-third-octave bands of a voice match, with the nominal centers of IEC 61260 from
/// 63 Hz to 16 kHz. Band 0 is 63 Hz. A band reaches from its center divided by 2^(1/6) to its
/// center times 2^(1/6), so the bands span 56.1 Hz to 17.96 kHz.
public enum ThirdOctave {
    public static let centers: [Double] = [
        63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000,
        6300, 8000, 10000, 12500, 16000,
    ]
    public static let bandCount = centers.count

    /// The lower and the upper edge of `band`, in Hz.
    public static func edges(of band: Int) -> (lower: Double, upper: Double) {
        let ratio = pow(2.0, 1.0 / 6.0)
        return (centers[band] / ratio, centers[band] * ratio)
    }

    /// One gain in dB for each band, band 0 first.
    public struct Gains: Hashable, Sendable {
        public let decibels: [Double]

        /// Nil unless there is one finite value for each band.
        public init?(decibels: [Double]) {
            guard decibels.count == ThirdOctave.bandCount, decibels.allSatisfy(\.isFinite) else { return nil }
            self.decibels = decibels
        }
    }
}
