import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The role strip and glyph of a header row (decision 0060, C13, U12, ui-audit A7).
extension HeaderRowTests {
    /// The role color of `appearance` in the color space of the capture, as 8-bit RGB.
    func rgb(_ role: Track.Role, _ appearance: NSAppearance, _ image: CGImage) throws -> (Int, Int, Int) {
        let space = try #require(image.colorSpace.flatMap(NSColorSpace.init(cgColorSpace:)))
        var color: NSColor?
        appearance.performAsCurrentDrawingAppearance { color = role.color.usingColorSpace(space) }
        let resolved = try #require(color)
        return (
            Int(resolved.redComponent * 255), Int(resolved.greenComponent * 255), Int(resolved.blueComponent * 255)
        )
    }

    /// C13 and A7: in light and dark mode, the 4 pt strip of a row with a role has the role color,
    /// and no pixel right of the strip has it, so the glyph is no colored tile. A row with no role
    /// has no pixel of a role color.
    @Test func aRoleColorsOnlyTheStripAndNoRoleShowsNothing() async throws {
        let (model, studio) = try await model(tracks: 4)
        let ids = studio.session.tracks.map(\.id)
        let roles: [Track.Role?] = [.dialogue, .music, .effects, nil]
        for (id, role) in zip(ids, roles) where role != nil { model.setRole(role, tracks: [id]) }
        try #require(studio.session.tracks.map(\.role) == roles, "the edits set the roles")
        let (lane, width) = (50.0, 340.0)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let (window, host) = rows(model, studio, laneHeight: lane, width: width)
            let appearance = try #require(NSAppearance(named: name))
            window.appearance = appearance
            window.orderFront(nil)
            drawNow(window)
            try await Task.sleep(for: .milliseconds(200))
            let capture = try await TimelineColorTests.capture(window)
            func pixels(_ row: Int, _ x: Range<Double>) throws -> [UInt32] {
                // 2 pt off the row edges: the separator line is at the bottom.
                let rect = NSRect(
                    x: x.lowerBound, y: Double(row) * lane + 2, width: x.upperBound - x.lowerBound, height: lane - 4)
                return try TimelineRulerTests.pixels(of: host.convert(rect, to: nil), capture, window)
            }
            let colors = try Track.Role.allCases.map { try rgb($0, appearance, capture) }
            func near(_ pixel: UInt32, _ color: (Int, Int, Int)) -> Bool {
                let (r, g, b) = (Int(pixel >> 16 & 0xFF), Int(pixel >> 8 & 0xFF), Int(pixel & 0xFF))
                return max(abs(r - color.0), abs(g - color.1), abs(b - color.2)) <= 24
            }
            for (row, role) in roles.enumerated() {
                let label = "\(name.rawValue), row \(row), \(role.map(\.rawValue) ?? "no role")"
                guard let role else {
                    let any = try pixels(row, 0..<width).filter { pixel in colors.contains { near(pixel, $0) } }
                    #expect(any.isEmpty, "no strip and no glyph: \(label): \(any.count) pixels")
                    continue
                }
                let color = colors[Track.Role.allCases.firstIndex(of: role)!]
                let strip = try pixels(row, 0..<4)
                let inStrip = strip.filter { near($0, color) }.count
                #expect(inStrip * 10 >= strip.count * 9, "the strip: \(label): \(inStrip) of \(strip.count)")
                let right = try pixels(row, 4..<width).filter { near($0, color) }.count
                #expect(right == 0, "only the 4 pt strip has the role color: \(label): \(right) pixels")
            }
            window.close()
        }
        await model.close()
    }

    /// U12 and A7: each role has its own system symbol, so the role does not depend on the strip
    /// color alone, and the glyph is no letter that reads as the Mute "M".
    @Test func eachRoleHasItsOwnSystemSymbol() {
        let symbols = Track.Role.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count, "\(symbols)")
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
        }
    }

    /// The glyph comes out of the name width, so a row with a role and a full live state stays
    /// inside the row at each width gate.
    @Test func aRowWithARoleStaysInsideTheRowAtEachWidthGate() async throws {
        let (model, studio) = try await model(tracks: 3)
        studio.liveTracks["t1"] = LiveTrack(state: .deviceLost, droppedFrames: 0, peak: 0)
        studio.liveTracks["t2"] = LiveTrack(
            state: .recording, droppedFrames: 3, peak: 0.1, shortTerm: LUFS(value: -17.4))
        model.setRole(.dialogue, tracks: ["t1"])
        model.setRole(.music, tracks: ["t2", "t3"])
        let forms = [
            (50.0, [TrackHeaders.muteSoloWidth, TrackHeaders.monitorWidth, TrackHeaders.compactLoudnessWidth]),
            (
                100.0,
                [TrackHeaders.muteSoloTwoLineWidth, TrackHeaders.monitorTwoLineWidth, TrackHeaders.faderTwoLineWidth]
            ),
        ]
        for (lane, widths) in forms {
            for width in widths {
                let (window, host) = rows(model, studio, laneHeight: lane, width: width)
                let out = outside(host, width: width)
                #expect(out.isEmpty, "inside the row: \(lane) pt lanes at \(width) pt: \(out)")
                window.close()
            }
        }
        await model.close()
    }
}
