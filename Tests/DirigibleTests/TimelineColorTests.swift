import AppKit
import Darwin
import DirigibleCore
import Testing

@testable import DirigibleApp

/// The window server did not show the window at its frame within the limit of the capture.
struct WindowCaptureError: Error, CustomStringConvertible {
    let description: String
}

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

    /// A capture of `window` on screen, in the color space of the display, when the window server
    /// shows the window at its frame. `shot` gives an image and the window server bounds of the
    /// window. The capture API is deprecated in macOS 14 and has no replacement without a
    /// permission prompt, so the test calls it through its symbol, with no deprecation warning.
    static func capture(
        _ window: NSWindow, limit: Duration = .seconds(30),
        shot: @MainActor (NSWindow) throws -> (CGImage?, CGRect?) = shot
    ) async throws -> CGImage {
        let end = ContinuousClock.now + limit
        let frame = screenBounds(of: window)
        let size = (
            Int((frame.width * window.backingScaleFactor).rounded()),
            Int((frame.height * window.backingScaleFactor).rounded())
        )
        while true {
            let (image, bounds) = try shot(window)
            if let image, bounds == frame, (image.width, image.height) == size { return image }
            guard ContinuousClock.now < end else {
                let pixels = image.map { "\($0.width) x \($0.height) px" } ?? "no image"
                throw WindowCaptureError(
                    description: "the window server did not show the window at \(frame) (\(size.0) x \(size.1) px) "
                        + "within \(limit): last \(pixels) at \(String(describing: bounds))")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// An image of the window and its window server bounds, read before and after the image: nil
    /// when they differ.
    static func shot(_ window: NSWindow) throws -> (CGImage?, CGRect?) {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"))
        let before = serverBounds(of: window)
        // Options: the one window (8); image: the bounds with no frame (1) at the best resolution (8).
        let image = unsafeBitCast(symbol, to: Capture.self)(.null, 8, UInt32(window.windowNumber), 1 | 8)?
            .takeRetainedValue()
        let after = serverBounds(of: window)
        return (image, before == after ? after : nil)
    }

    /// The bounds of the window in the window list of the window server (top-left origin).
    static func serverBounds(of window: NSWindow) -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber))
        guard let info = (list as? [[String: Any]])?.first,
            let bounds = info[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    /// The frame of the window in the coordinates of the window server: the origin at the top left
    /// of the main display.
    static func screenBounds(of window: NSWindow) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = window.frame
        return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
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

        let image = try await Self.capture(window)
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
    /// Code gate 1 item 2: in Mission Control the window server shows the window smaller and at
    /// another place, and a capture then gives that image (probe 2026-09-28: 1936 x 436 px for a
    /// window of 1780 x 400 pt). The pixel tests then read the wrong pixels. So a capture waits
    /// until the window server shows the window at its frame, at the backing scale.
    @Test func aCaptureWaitsUntilTheWindowServerShowsTheWindowAtItsFrame() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 60, width: 100, height: 50), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let scale = window.backingScaleFactor
        let frame = Self.screenBounds(of: window)
        func image(_ width: Int, _ height: Int) throws -> CGImage {
            let context = try #require(
                CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
            return try #require(context.makeImage())
        }
        let full = try image(Int(100 * scale), Int(50 * scale))
        // A thumbnail, the last frame of the zoom back (full size, not yet at its place), an image of
        // another size at the frame, then the window at its frame.
        let shots: [(CGImage?, CGRect?)] = [
            (try image(97, 24), frame.insetBy(dx: 26, dy: 13)), (full, frame.offsetBy(dx: 56, dy: 0)),
            (try image(full.width - 2, full.height - 1), frame), (full, frame),
        ]
        var calls = 0
        let shown = try await Self.capture(window) { _ in
            calls += 1
            return shots[min(calls, shots.count) - 1]
        }
        #expect(shown === full && calls == 4, "calls \(calls)")

        await #expect(throws: WindowCaptureError.self) {
            _ = try await Self.capture(window, limit: .milliseconds(200)) { _ in shots[0] }
        }
    }
}
