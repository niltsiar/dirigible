import Foundation

/// Whole decibels of noise reduction, 1 to 30 (decision 0054): the one parse of the amount for the
/// app, the CLI, and MCP.
public struct NoiseReduction: Hashable, Sendable {
    public static let range = 1...30
    /// The amount of Tools > Reduce Noise and the default of the command and the tool.
    public static let standard = NoiseReduction(decibels: 12)!
    public let decibels: Int

    /// Nil outside `range`.
    public init?(decibels: Int) {
        guard Self.range.contains(decibels) else { return nil }
        self.decibels = decibels
    }

    /// The AUSoundIsolation wet/dry mix, which is linear: 100 x (1 - 10^(-dB/20)), so 12 dB gives
    /// 74.88 %.
    var wetDryMixPercent: Float { Float(100 * (1 - pow(10, -Double(decibels) / 20))) }
}
