import Foundation
import Testing

@testable import DirigibleApp

/// Run 1b criterion H9: the light and dark lane palettes, the selection blend, and the contrast of
/// the clip label.
struct LanePaletteTests {
    @Test func theDarkPaletteHasItsLiterals() {
        let dark = LanePalette.dark(accent: 0xFF00_7AFF)
        #expect(dark.lane == 0xFF1E_1F22, "dark palette")
        #expect(dark.clip == 0xFF2C_3E57, "dark palette")
        #expect(dark.peak == 0xFF6E_9FE0, "dark palette")
        #expect(dark.rms == 0xFFA9_C8F2, "dark palette")
        #expect(dark.missing == 0xFF4A_2427, "dark palette")
        #expect(dark.missingOutline == 0xFFFF_6961, "dark palette")
        #expect(dark.label == 0xFFE6_E6E6, "dark palette")
        let light = LanePalette.light
        #expect(
            [dark.marker, dark.chapter, dark.inPoint, dark.outPoint]
                == [light.marker, light.chapter, light.inPoint, light.outPoint], "dark palette")
    }

    /// Each channel goes 30 % toward the accent, rounded to the nearest: 1E1F22 with 007AFF gives
    /// 153A64. The light band stays half as bright.
    @Test func theSelectionBlendsTowardTheAccent() {
        #expect(LanePalette.dark(accent: 0xFF00_7AFF).selected(0xFF1E_1F22) == 0xFF15_3A64, "selection blend")
        #expect(LanePalette.dark(accent: 0xFFFF_FFFF).selected(0xFF00_0000) == 0xFF4D_4D4D, "selection blend")
        #expect(LanePalette.light.selected(0xFFE8_ECF2) == 0xFF74_7679, "selection blend: light halves")
    }

    /// WCAG 2 contrast of the label on the clip: 7:1 or more in both palettes and their live
    /// palettes (the take label on the red live region, run 2026-10-11-ui-polish-header C15).
    @Test func theLabelHasAContrastOfSevenOnTheClip() {
        let palettes = [LanePalette.light, .dark(accent: 0xFF00_7AFF)]
        for palette in palettes + palettes.map(\.live) {
            let ratio = contrast(palette.label, palette.clip)
            #expect(ratio >= 7, "label contrast \(ratio)")
        }
    }

    /// The live palette reads as red, its fill stays apart from the missing-media fill (CIE76
    /// distance 20 or more), and its waveform shows on its fill: a take must not look broken (run
    /// 2026-10-11-ui-polish-header code gate 1 item 2).
    @Test(arguments: [LanePalette.light, .dark(accent: 0xFF00_7AFF)])
    func theLivePaletteIsRedAndApartFromMissing(palette: LanePalette) {
        let live = palette.live
        for pixel in [live.clip, live.peak, live.rms] {
            let (r, g, b) = (Int(pixel >> 16 & 0xFF), Int(pixel >> 8 & 0xFF), Int(pixel & 0xFF))
            #expect(r >= g + 40 && r >= b + 40, "red: \(String(pixel, radix: 16))")
        }
        let distance = deltaE(live.clip, palette.missing)
        #expect(distance >= 20, "the live fill and the missing fill: \(distance)")
        #expect(contrast(live.peak, live.clip) >= 1.5 && contrast(live.rms, live.peak) >= 1.5, "the waveform shows")
        #expect(live.lane == palette.lane, "the lane color stays")
    }

    /// The CIE76 distance of two sRGB pixels.
    private func deltaE(_ a: UInt32, _ b: UInt32) -> Double {
        func lab(_ pixel: UInt32) -> [Double] {
            let (r, g, bl) = (linear(pixel >> 16), linear(pixel >> 8), linear(pixel))
            let xyz = [
                (0.4124 * r + 0.3576 * g + 0.1805 * bl) / 0.95047, 0.2126 * r + 0.7152 * g + 0.0722 * bl,
                (0.0193 * r + 0.1192 * g + 0.9505 * bl) / 1.08883,
            ]
            let f = xyz.map { $0 > 0.008856 ? pow($0, 1.0 / 3) : 7.787 * $0 + 16.0 / 116 }
            return [116 * f[1] - 16, 500 * (f[0] - f[1]), 200 * (f[1] - f[2])]
        }
        return sqrt(zip(lab(a), lab(b)).map { ($0 - $1) * ($0 - $1) }.reduce(0, +))
    }

    private func linear(_ channel: UInt32) -> Double {
        let c = Double(channel & 0xFF) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ pixel: UInt32) -> Double {
            0.2126 * linear(pixel >> 16) + 0.7152 * linear(pixel >> 8) + 0.0722 * linear(pixel)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
