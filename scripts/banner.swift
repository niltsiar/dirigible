// Draw the README banners: docs/images/banner-light.png and banner-dark.png, 1600 x 400 px, from
// the icon preview, the name, and the tagline.
// usage: swift scripts/banner.swift <icon preview folder> <out folder>
// Run `make icon-preview` first; its folder is build/icon-preview (Light.png and Dark.png).
// Exit: 0 written, 1 a missing icon or a text that does not fit, 2 usage.
import AppKit

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 2, let icons = arguments.first, let out = arguments.last else {
    fail("usage: swift scripts/banner.swift <icon preview folder> <out folder>", 2)
}

func color(_ red: Double, _ green: Double, _ blue: Double) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
}

// The navy values are from the fill of Support/AppIcon.icon/icon.json.
let looks: [(icon: String, file: String, top: NSColor, bottom: NSColor, name: NSColor, tagline: NSColor)] = [
    (
        "Light.png", "banner-light.png", color(0.953, 0.961, 0.980), color(0.953, 0.961, 0.980),
        color(0.106, 0.165, 0.322), color(0.275, 0.376, 0.604)
    ),
    (
        "Dark.png", "banner-dark.png", color(0.043, 0.063, 0.141), color(0.118, 0.165, 0.298),
        .white, NSColor.white.withAlphaComponent(0.85)
    ),
]

// One point is one pixel: the context of a bitmap with no Retina scale.
let width = 1600
let height = 400
let textX = 400.0
func name(_ color: NSColor) -> NSAttributedString {
    NSAttributedString(
        string: "Dirigible",
        attributes: [.font: NSFont.systemFont(ofSize: 120, weight: .bold), .foregroundColor: color])
}
func tagline(_ color: NSColor) -> NSAttributedString {
    NSAttributedString(
        string: "Podcast recorder and editor for macOS",
        attributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: color])
}
guard textX + max(name(.black).size().width, tagline(.black).size().width) <= Double(width) - 40 else {
    fail("banner.swift: the text does not fit in \(width) px", 1)
}

for look in looks {
    guard let icon = NSImage(contentsOfFile: "\(icons)/\(look.icon)") else {
        fail("banner.swift: no \(icons)/\(look.icon). Run make icon-preview first.", 1)
    }
    // No alpha channel: the file is about 20 % smaller, and the banner is opaque.
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3,
        hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGradient(starting: look.top, ending: look.bottom)!.draw(
        in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)
    icon.draw(in: NSRect(x: 50, y: 40, width: 320, height: 320))
    name(look.name).draw(at: NSPoint(x: textX, y: 185))
    tagline(look.tagline).draw(at: NSPoint(x: textX, y: 95))
    NSGraphicsContext.restoreGraphicsState()
    let path = "\(out)/\(look.file)"
    guard let png = bitmap.representation(using: .png, properties: [:]),
        (try? png.write(to: URL(fileURLWithPath: path))) != nil
    else { fail("banner.swift: cannot write \(path)", 1) }
    print(path)
}
