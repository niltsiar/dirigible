import DirigibleCore
import Foundation

extension NoiseReduction {
    /// The AUSoundIsolation wet/dry mix, which is linear: 100 x (1 - 10^(-dB/20)), so 12 dB gives
    /// 74.88 %.
    var wetDryMixPercent: Float { Float(100 * (1 - pow(10, -Double(decibels) / 20))) }
}
