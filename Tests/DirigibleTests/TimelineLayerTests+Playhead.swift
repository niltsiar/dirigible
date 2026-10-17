import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The playhead is a neutral line with a halo and a head on the ruler (run timeline-clarity, L1-S5,
/// U-c2 and U-c3). It is red only as the record head of a take.
extension TimelineLayerTests {
    static let play = Playback.playing(Shuttle(direction: .forward, rate: .one))

    /// The sRGB components of a color, empty for no color.
    static func srgb(_ color: CGColor?) -> [Double] {
        guard let color, let space = CGColorSpace(name: CGColorSpace.sRGB),
            let parts = color.converted(to: space, intent: .defaultIntent, options: nil)?.components
        else { return [] }
        return parts.map { Double($0) }
    }

    /// systemRed in the appearance `name`.
    static func red(_ name: NSAppearance.Name) -> [Double] {
        var color: CGColor?
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance { color = NSColor.systemRed.cgColor }
        return srgb(color)
    }

    static func same(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.01 }
    }

    /// The core, the two halos, and the fill and the outline of the head, as components.
    struct PlayheadLook {
        var core: [Double]
        var halos: [[Double]]
        var fill: [Double]
        var outline: [Double]
        var coreWidth: Double
        var head: CGSize
    }

    func look(_ view: TimelineScrollView) -> PlayheadLook {
        let line = view.lanes.playhead
        return PlayheadLook(
            core: Self.srgb(line.backgroundColor), halos: (line.sublayers ?? []).map { Self.srgb($0.backgroundColor) },
            fill: Self.srgb(view.ruler.head.shape.fillColor), outline: Self.srgb(view.ruler.head.shape.strokeColor),
            coreWidth: Double(line.bounds.width), head: view.ruler.head.shape.bounds.size)
    }

    func isNeutral(_ found: PlayheadLook, dark: Bool) -> Bool {
        let core = dark ? [1, 1, 1, 1] : [0x1D / 255.0, 0x1D / 255.0, 0x1F / 255.0, 1]
        let halo = dark ? [0, 0, 0, 0.7] : [1, 1, 1, 0.85]
        return Self.same(found.core, core) && found.halos.count == 2 && found.halos.allSatisfy { Self.same($0, halo) }
            && Self.same(found.fill, core) && Self.same(found.outline, halo)
    }

    /// C9: the line and the head are neutral when stopped, during play, and after a take, and red
    /// during a take. The halos stay. An appearance change and Increase Contrast apply with no tick.
    @Test func thePlayheadIsNeutralAndRedOnlyAsTheRecordHead() async throws {
        let (_, _, window, view) = try await lanes()
        view.tick(playhead: 0, playback: .stopped)
        #expect(isNeutral(look(view), dark: false), "stopped: \(look(view))")
        view.tick(playhead: 48_000, playback: Self.play)
        #expect(isNeutral(look(view), dark: false), "playing: \(look(view))")

        view.tick(playhead: 96_000, playback: .stopped, taking: true)
        let red = Self.red(.aqua)
        let taking = look(view)
        #expect(Self.same(taking.core, red) && Self.same(taking.fill, red), "during a take: \(taking)")
        #expect(taking.halos.count == 2 && taking.halos.allSatisfy { Self.same($0, [1, 1, 1, 0.85]) }, "\(taking)")

        view.tick(playhead: 96_000, playback: .stopped)
        #expect(isNeutral(look(view), dark: false), "after the take: \(look(view))")

        window.appearance = NSAppearance(named: .darkAqua)
        #expect(isNeutral(look(view), dark: true), "dark, no tick: \(look(view))")
        view.tick(playhead: 96_000, playback: .stopped, taking: true)
        #expect(Self.same(look(view).core, Self.red(.darkAqua)), "dark, during a take")
        view.tick(playhead: 96_000, playback: .stopped)
        window.appearance = NSAppearance(named: .aqua)
        #expect(isNeutral(look(view), dark: false), "light, no tick: \(look(view))")

        view.lanes.increasesContrast = true
        #expect(look(view).coreWidth == 2 && look(view).head == CGSize(width: 13, height: 12), "\(look(view))")
        view.lanes.increasesContrast = false
        #expect(look(view).coreWidth == 1 && look(view).head == CGSize(width: 11, height: 10), "\(look(view))")
    }

    /// The ruler x of the document x of `frame`, and the ruler x of the left edge of the lanes in view.
    func rulerX(_ view: TimelineScrollView, frame: Double) -> (head: Double, edge: Double) {
        let at = { (x: Double) in Double(view.ruler.convert(NSPoint(x: x, y: 0), from: view.documentView).x) }
        return (at(frame / view.framesPerPoint), at(Double(view.shown.minX)))
    }

    /// C10: the head is at the ruler x of the playhead inside a container that starts at the lane edge.
    func expectHead(_ view: TimelineScrollView, at frame: Double, _ step: String) {
        let head = view.ruler.head
        let (x, edge) = rulerX(view, frame: frame)
        #expect(head.container.masksToBounds && abs(Double(head.container.frame.minX) - edge) < 0.5, "\(step): edge")
        #expect(
            abs(Double(head.shape.position.x) - (x - edge)) < 0.5,
            "\(step): x \(head.shape.position.x), want \(x - edge)")
    }

    /// C10: a layout before the first display tick gives the head its place at the Studio playhead.
    @Test func theHeadHasItsPlaceBeforeTheFirstTick() async throws {
        let (_, studio, _, view) = try await lanes()
        expectHead(view, at: Double(studio.playhead.count), "before the first tick")
    }

    /// C10, C11 (tick): a play tick moves the head and draws no ruler. A scroll while stopped and a
    /// header width drag move it with no tick. A playhead left of the lanes in view shows no head.
    @Test func thePlayheadHeadMovesWithNoRulerDraw() async throws {
        let (_, _, window, view) = try await lanes()
        let ruler = view.ruler
        view.tick(playhead: 100_000, playback: Self.play)
        drawNow(window)
        let draws = ruler.draws
        for turn in 1...10 {
            let frame = 100_000 + Double(turn) * 6_000
            view.tick(playhead: frame, playback: Self.play)
            drawNow(window)
            expectHead(view, at: frame, "tick \(turn)")
        }
        #expect(ruler.draws == draws, "a play tick draws no ruler")

        view.tick(playhead: 400_000, playback: .stopped)
        let before = ruler.head.shape.position.x
        view.contentView.scroll(to: NSPoint(x: view.contentView.bounds.minX + 300, y: view.contentView.bounds.minY))
        view.reflectScrolledClipView(view.contentView)
        #expect(abs(Double(before - ruler.head.shape.position.x) - 300) < 0.5, "a scroll moves the head with no tick")
        expectHead(view, at: 400_000, "scroll")

        let edge = ruler.head.container.frame.minX
        view.headers.width = HeaderWidth(200)
        #expect(ruler.head.container.frame.minX != edge, "the header width moved the lane edge")
        expectHead(view, at: 400_000, "header width")

        // A seek shows the head, so the tick comes first and the scroll after it.
        view.tick(playhead: 100_000, playback: .stopped)
        let at = 100_000 / view.framesPerPoint
        func scroll(toShown x: Double) {
            let bounds = view.contentView.bounds
            view.contentView.scroll(to: NSPoint(x: x - view.contentView.contentInsets.left, y: bounds.minY))
            view.reflectScrolledClipView(view.contentView)
        }
        scroll(toShown: at + 100)
        expectHead(view, at: 100_000, "left of the view")
        #expect(ruler.head.shape.frame.maxX < 0, "no part of the head is in the container: \(ruler.head.shape.frame)")
        // At the edge, half of the head is cut at the edge.
        scroll(toShown: at)
        expectHead(view, at: 100_000, "at the edge")
        let frame = ruler.head.shape.frame
        #expect(frame.minX < 0 && frame.maxX > 0 && ruler.head.container.masksToBounds, "cut at the edge: \(frame)")
    }
}
