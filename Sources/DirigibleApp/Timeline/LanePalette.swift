import AppKit

/// The lane colors as pixels: 0xAARRGGBB in a little-endian word (BGRA in memory).
struct LanePalette: Equatable {
    var lane, clip, peak, rms, missing, missingOutline, label, marker, chapter, inPoint, outPoint: UInt32
    /// The accent color of the dark palette; nil in the light palettes. The overview clip color, and
    /// the dim, drop fill, and lane tint of Dark Mode, read it.
    var accent: UInt32?
    /// The system accent color: the outline of a selected clip, the color of its tint (decision
    /// 0038), and the color that the selection band blends toward. `light` has the default blue;
    /// `pick` gives the accent of the system.
    var outline: UInt32 = 0xFF00_7AFF
    /// The 2 pt join at a cut between two clips. Light: 3.05:1 on the clip color; the lane color
    /// gives 1.21:1 there. Dark: the lane color.
    var join: UInt32 = 0xFF5A_7BA6
    /// The clip bar at the top of a clip box, and the 1 pt edge in its bottom row: 3:1 or more
    /// against the clip and 1.5:1 or more against the peak color.
    var bar: UInt32 = 0xFFA9_C6EC
    var barEdge: UInt32 = 0xFF5A_7BA6

    static let light = LanePalette(
        lane: 0xFFE8_ECF2, clip: 0xFFC4_DAF5, peak: 0xFF7A_A7E0, rms: 0xFF1F_4F9E, missing: 0xFFF4_C4C4,
        missingOutline: 0xFFC8_2020, label: 0xFF26_2626, marker: 0xFFF2_8C1A, chapter: 0xFF8E_44AD,
        inPoint: 0xFF2E_A043, outPoint: 0xFFE0_3A3A)

    /// The lanes in light mode with the accent color of the system.
    static func light(accent: UInt32) -> LanePalette {
        var palette = light
        palette.outline = accent
        return palette
    }

    /// The lanes in Dark Mode (ux-visual-perf section 1). The label on the clip has a contrast of
    /// about 8.7:1. The lines keep their light colors.
    static func dark(accent: UInt32) -> LanePalette {
        var palette = light
        (palette.lane, palette.clip, palette.peak, palette.rms) = (0xFF1E_1F22, 0xFF2C_3E57, 0xFF6E_9FE0, 0xFFA9_C8F2)
        (palette.missing, palette.missingOutline, palette.label) = (0xFF4A_2427, 0xFFFF_6961, 0xFFE6_E6E6)
        (palette.liveClip, palette.livePeak, palette.liveRms) = (0xFF7A_2020, 0xFFE0_6E6E, 0xFFF2_A9A9)
        (palette.accent, palette.outline) = (accent, accent)
        palette.join = palette.lane
        (palette.bar, palette.barEdge) = (0xFF22_324A, 0xFFA8_C4EA)
        return palette
    }

    /// The clip, peak, and RMS colors of the live region while a take records: red, as in
    /// Hindenburg and Logic (run 2026-10-11-ui-polish-header U4). The fill is more saturated than
    /// the pale missing-media fill, so a take does not look broken (code gate 1 item 2).
    var liveClip: UInt32 = 0xFFFC_9898
    var livePeak: UInt32 = 0xFFD0_4848
    var liveRms: UInt32 = 0xFF7E_1414

    /// The palette of the live region while a take records. The finalize draws the normal palette,
    /// so its pixels equal the clips after the hand-off.
    var live: LanePalette {
        var palette = self
        (palette.clip, palette.peak, palette.rms, palette.bar) = (liveClip, livePeak, liveRms, liveClip)
        return palette
    }

    /// A pixel of a selected clip box: each channel 25 % toward the outline color, rounded to the
    /// nearest (decision 0038).
    func tinted(_ pixel: UInt32) -> UInt32 {
        var result: UInt32 = 0xFF00_0000
        for shift: UInt32 in [0, 8, 16] {
            let (c, o) = (Int((pixel >> shift) & 0xFF), Int((outline >> shift) & 0xFF))
            let step = o - c
            result |= UInt32(c + (step + (step < 0 ? -2 : 2)) / 4) << shift
        }
        return result
    }

    /// A pixel under the selection band: each channel 30 % toward the outline (accent) color, rounded
    /// to the nearest.
    func selected(_ pixel: UInt32) -> UInt32 {
        var result: UInt32 = 0xFF00_0000
        for shift: UInt32 in [0, 8, 16] {
            let (c, a) = (Int((pixel >> shift) & 0xFF), Int((outline >> shift) & 0xFF))
            let step = (a - c) * 3
            result |= UInt32(c + (step + (step < 0 ? -5 : 5)) / 10) << shift
        }
        return result
    }

    /// The label color for AppKit text.
    var labelColor: NSColor {
        func channel(_ shift: UInt32) -> Double { Double((label >> shift) & 0xFF) / 255 }
        return NSColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
    }
}

extension LanePalette {
    /// The palette of `appearance`: the appearance and the accent resolve together. The outline of
    /// a selected clip is the accent in both appearances (decision 0038).
    static func pick(for appearance: NSAppearance) -> LanePalette {
        var picked = LanePalette.light
        appearance.performAsCurrentDrawingAppearance {
            guard let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return }
            func channel(_ value: CGFloat) -> UInt32 { UInt32((value * 255).rounded()) }
            let pixel =
                0xFF00_0000 | channel(accent.redComponent) << 16 | channel(accent.greenComponent) << 8
                | channel(accent.blueComponent)
            picked =
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? .dark(accent: pixel) : .light(accent: pixel)
        }
        return picked
    }
}
