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

    /// The red live palette of the prototype (run 2026-10-11-ui-polish-header U4).
    @Test func theLivePaletteIsRed() {
        let light = LanePalette.light.live
        #expect([light.clip, light.peak, light.rms] == [0xFFF5_C4C4, 0xFFE0_7A7A, 0xFF9E_1F1F])
        let dark = LanePalette.dark(accent: 0xFF00_7AFF).live
        #expect([dark.clip, dark.peak, dark.rms] == [0xFF57_2C2C, 0xFFE0_6E6E, 0xFFF2_A9A9])
        #expect(dark.lane == LanePalette.dark(accent: 0xFF00_7AFF).lane, "the lane color stays")
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ pixel: UInt32) -> Double {
            func channel(_ shift: UInt32) -> Double {
                let c = Double((pixel >> shift) & 0xFF) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
