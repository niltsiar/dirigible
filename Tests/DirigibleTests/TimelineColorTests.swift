import AppKit
import Darwin
import DirigibleCore
import Testing

@testable import DirigibleApp

/// Timeline-layer criterion 5: the lanes show the colors of the `draw(_:)` path of main on screen.
/// A snapshot (`cacheDisplay`) is not the screen: it draws a `draw(_:)` view with color matching
/// (clip red 196), but it copies the contents of a layer with no matching (clip red 209, the
/// same for an sRGB image as for the tagged surface). So the test reads a capture of the window.
@Suite(.serialized) @MainActor struct TimelineColorTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    /// The path of main: a layer-backed view that draws an sRGB image of the clip color in
    /// `draw(_:)`.
    final class DrawPathView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            var pixel = LanePalette.light.clip
            guard let provider = CGDataProvider(data: Data(bytes: &pixel, count: 4) as CFData),
                let image = CGImage(
                    width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(
                        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                    ),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { return }
            NSGraphicsContext.current?.cgContext.draw(image, in: bounds)
        }
    }

    /// A capture of `window` on screen, in the color space of the display. The capture API is
    /// deprecated in macOS 14 and has no replacement without a permission prompt, so the test calls
    /// it through its symbol, with no deprecation warning.
    static func capture(_ window: NSWindow) throws -> CGImage {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"))
        // Options: the one window (8); image: the bounds with no frame (1) at the best resolution (8).
        return try #require(
            unsafeBitCast(symbol, to: Capture.self)(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue(),
            "no capture of the window")
    }

    /// A clip pixel of the lanes on screen has the value of the same sRGB color drawn in a
    /// `draw(_:)` view, within 1 per channel of the display (2026-09-27, Intel Mac, Color LCD: lanes
    /// R 200 G 218 B 242, draw path R 200 G 218 B 243; P2: 200 218 242 for both).
    @Test func aLanePixelOnScreenHasTheColorOfTheDrawPath() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 20, audio: true), app: app)
        let (window, view) = standaloneLanes(model, studio, onScreen: true)
        let reference = DrawPathView(frame: NSRect(x: 10, y: 10, width: 40, height: 40))
        reference.wantsLayer = true
        try #require(window.contentView).addSubview(reference)
        drawNow(window)
        try await Task.sleep(for: .milliseconds(100))

        let image = try Self.capture(window)
        let data = try #require(image.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        try #require(
            image.bitsPerPixel == 32 && image.bitmapInfo.contains(.byteOrder32Little), "BGRA: \(image.bitmapInfo)")
        let scale = Double(image.width) / window.frame.width
        func color(at point: NSPoint) -> [UInt8] {
            // The capture has row 0 at the top of the window; the window has y 0 at the bottom.
            let (x, y) = (Int(point.x * scale), Int((window.frame.height - point.y) * scale))
            let offset = y * image.bytesPerRow + x * 4
            return [bytes[offset + 2], bytes[offset + 1], bytes[offset]]
        }
        // Lane 1 at x 300 pt: the clip c1 of a silent file (no waveform), above its label.
        let lane = color(at: view.lanes.convert(NSPoint(x: 300, y: 30), to: nil))
        let drawn = color(at: reference.convert(NSPoint(x: 20, y: 20), to: nil))

        #expect(
            zip(lane, drawn).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, "lanes RGB \(lane), draw path RGB \(drawn)")
        #expect(drawn != [0, 0, 0], "the capture shows the window")
        window.close()
        await model.close()
    }
}
