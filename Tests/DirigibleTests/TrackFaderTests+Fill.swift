import AppKit
import Testing

@testable import DirigibleApp

/// Code gate 1: the fill of the track fader in Light Mode and in Dark Mode.
extension TrackFaderTests {
    /// The brightness of the fill and of the track of the slider at -20 dB in `appearance`, over
    /// the window background: a pixel of the mid row at 10 % and at 70 % of the width.
    func fillAndTrack(_ appearance: NSAppearance.Name) throws -> (fill: Double, track: Double) {
        let view = TrackFaderView()
        view.appearance = NSAppearance(named: appearance)
        view.slider.show(-20)
        let slider = view.slider
        let bitmap = try #require(slider.bitmapImageRepForCachingDisplay(in: slider.bounds))
        slider.cacheDisplay(in: slider.bounds, to: bitmap)
        var background = 0.0
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            background =
                NSColor.windowBackgroundColor.usingColorSpace(.sRGB).map { Double($0.brightnessComponent) } ?? 0
        }
        func brightness(_ share: Double) throws -> Double {
            let x = Int(Double(bitmap.pixelsWide) * share)
            let color = try #require(bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            return color.brightnessComponent * color.alphaComponent + background * (1 - color.alphaComponent)
        }
        return (try brightness(0.1), try brightness(0.7))
    }

    /// Code gate 1: the fill shows in Light Mode and in Dark Mode. `NSSlider` blends its fill
    /// color into the track, so a white fill drew 0.38 on a track of 0.28 in Dark Mode.
    @Test func theFillShowsInLightAndDarkMode() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let (fill, track) = try fillAndTrack(name)
            #expect(abs(fill - track) >= 0.25, "code gate 1: \(name.rawValue) fill \(fill), track \(track)")
        }
    }
}
