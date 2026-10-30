import AppKit
import DirigibleCore
import DirigibleTimeline
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The mark of the current unit (run transcript-1, landing 2, criterion P4).
extension TranscriptPaneTests {
    /// The line fragments of the text range `range` of the pane, in the coordinates of the pane.
    func segments(of range: Range<Int>, in pane: TranscriptTextView) throws -> [CGRect] {
        let manager = try #require(pane.textLayoutManager)
        let content = try #require(manager.textContentManager)
        let start = try #require(content.location(manager.documentRange.location, offsetBy: range.lowerBound))
        let end = try #require(content.location(start, offsetBy: range.count))
        let span = try #require(NSTextRange(location: start, end: end))
        var found: [CGRect] = []
        manager.enumerateTextSegments(in: span, type: .standard, options: []) { _, frame, _, _ in
            found.append(frame.offsetBy(dx: pane.textContainerOrigin.x, dy: pane.textContainerOrigin.y))
            return true
        }
        return found
    }

    /// The underline of a segment: 2 pt high, 1 pt under the line fragment.
    func underline(_ segment: CGRect, width: Double = 2) -> CGRect {
        CGRect(x: segment.minX, y: segment.maxY + 1, width: segment.width, height: width)
    }

    func secondUnit(_ pane: TranscriptTextView) throws -> TranscriptText.Unit {
        let shown = try #require(pane.shown)
        return try #require(shown.text.units.first { $0.frames.lowerBound == Self.second })
    }

    func opened(_ name: String) async throws -> (SessionWindow, Studio, NSWindow, TranscriptTextView) {
        let (model, studio, window, _) = try await open(try await package(name: name))
        model.showTranscript()
        return (model, studio, window, try await waitForPane(window))
    }

    /// P4: after a seek and after a tick, the layer holds one underline at each line fragment of
    /// the current unit and none elsewhere, in the color of the playhead core, with no fill and no
    /// change to the text storage.
    @Test func tickHighlightsTheCurrentUnit() async throws {
        let (model, studio, _, pane) = try await opened("tick")
        let (text, replacements, builds) = (pane.string, pane.replacements, pane.builds)
        let unit = try secondUnit(pane)
        pane.appearance = NSAppearance(named: .aqua)

        await seek(studio, to: Self.second)
        model.transcriptTick(frame: Self.second)
        let expected = try segments(of: unit.text, in: pane).map { underline($0) }
        #expect(!expected.isEmpty)
        #expect(pane.underlines.map(\.frame) == expected)
        #expect(
            pane.underlines.allSatisfy {
                $0.backgroundColor == PlayheadColors(appearance: .init(named: .aqua)!, taking: false).core
            })
        #expect(pane.underlines.allSatisfy { $0.cornerRadius == 1 })

        model.transcriptTick(frame: unit.frames.upperBound - 1)
        #expect(pane.underlines.map(\.frame) == expected, "the last frame of the unit is in it")
        model.transcriptTick(frame: unit.frames.upperBound)
        let part = try #require(pane.shown).text.units[3]
        let next = try segments(of: part.text, in: pane)
        #expect(pane.underlines.map(\.frame) == next.map { underline($0) }, "the end frame is in the next unit only")
        model.transcriptTick(frame: Self.afterSecond)
        #expect(pane.underlines.isEmpty, "a gap holds no unit")

        model.transcriptTick(frame: Self.second)
        pane.appearance = NSAppearance(named: .darkAqua)
        #expect(pane.underlines.allSatisfy { $0.backgroundColor == CGColor(gray: 1, alpha: 1) }, "white in dark mode")
        pane.appearance = NSAppearance(named: .aqua)
        let ink = CGColor(srgbRed: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 1)
        #expect(pane.underlines.allSatisfy { $0.backgroundColor == ink }, "dark gray in light mode")

        for tick in 0..<100 { model.transcriptTick(frame: Self.second + Frames(tick * 10)) }
        #expect((pane.string, pane.replacements, pane.builds) == (text, replacements, builds), "a tick edits no text")
        await model.close()
    }

    /// P4: Increase Contrast makes the underline 3 pt, also while the pane shows.
    @Test func increaseContrastWidensTheUnderline() async throws {
        let (model, _, _, pane) = try await opened("contrast")
        let unit = try secondUnit(pane)
        pane.increaseContrast = false
        model.transcriptTick(frame: Self.second)
        let segments = try segments(of: unit.text, in: pane)
        #expect(pane.underlines.map(\.frame) == segments.map { underline($0, width: 2) })

        pane.increaseContrast = true
        #expect(pane.underlines.map(\.frame) == segments.map { underline($0, width: 3) })
        pane.increaseContrast = false
        #expect(pane.underlines.map(\.frame) == segments.map { underline($0, width: 2) })
        await model.close()
    }
}
