import AppKit
import DirigibleCore
import DirigibleTimeline
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The follow of the playhead in the pane (run transcript-1, landing 2, criteria P4, P18).
extension TranscriptPaneTests {
    /// A window with a short pane and 600 words in one paragraph, so the text is much taller than the pane.
    func scrolling(_ name: String) async throws -> (SessionWindow, Studio, NSWindow, TranscriptTextView) {
        var words: [(Double, Double, String)] = []
        for index in 0..<600 {
            let start: Double = 0.5 + Double(index) * 0.03
            words.append((start, start + 0.03, "w\(index)"))
        }
        let (model, studio, window, _) = try await open(try await package(name: name, words: words))
        window.setFrame(NSRect(x: 100, y: 100, width: 1000, height: 500), display: true)
        model.showTranscript()
        let pane = try await waitForPane(window)
        window.contentView?.layoutSubtreeIfNeeded()
        return (model, studio, window, pane)
    }

    func unit(_ index: Int, in pane: TranscriptTextView) throws -> TranscriptText.Unit {
        try #require(pane.shown).text.units[index]
    }

    /// A scroll-wheel event, as the mouse makes it: `lines` is the vertical distance in lines.
    func scrollWheel(_ lines: Int32) throws -> NSEvent {
        let cg = try #require(
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0))
        return try #require(NSEvent(cgEvent: cg))
    }

    /// How far the top of `unit` is from the top of the visible text.
    func offset(of unit: TranscriptText.Unit, in pane: TranscriptTextView) throws -> Double {
        let segment = try #require(try segments(of: unit.text, in: pane).first)
        return segment.minY - pane.scrollOrigin
    }

    /// P4: with the follow on, a unit that becomes current goes to about one third from the top.
    /// Its own scroll does not turn the follow off.
    @Test func ownScrollKeepsTheFollow() async throws {
        let (model, _, _, pane) = try await scrolling("own")
        let follow = model.transcriptFollow
        let height = try #require(pane.enclosingScrollView).contentView.bounds.height
        try #require(follow.isOn, "the follow starts on")

        model.transcriptTick(frame: try unit(300, in: pane).frames.lowerBound)
        #expect(pane.scrollOrigin > 100, "the text scrolled: \(pane.scrollOrigin)")
        let third = try offset(of: try unit(300, in: pane), in: pane)
        #expect(abs(third - height / 3) < 1, "\(third) pt from the top in a pane of \(height) pt")

        for index in 301..<401 { model.transcriptTick(frame: try unit(index, in: pane).frames.lowerBound) }
        #expect(follow.isOn, "100 own scrolls")
        let later = try offset(of: try unit(400, in: pane), in: pane)
        #expect(abs(later - height / 3) < 1, "the unit stays at the third: \(later)")
        await model.close()
    }

    /// P4: one scroll-wheel event turns the follow off, and then a tick does not scroll.
    @Test func userScrollStopsTheFollow() async throws {
        let (model, _, _, pane) = try await scrolling("user")
        model.transcriptTick(frame: try unit(300, in: pane).frames.lowerBound)
        try #require(model.transcriptFollow.isOn)

        pane.scrollWheel(with: try scrollWheel(-5))
        #expect(!model.transcriptFollow.isOn)

        let origin = pane.scrollOrigin
        model.transcriptTick(frame: try unit(500, in: pane).frames.lowerBound)
        #expect(pane.scrollOrigin == origin, "a tick with the follow off does not scroll")
        await model.close()
    }

    /// P4, P18: the toggle, a play start, and a seek turn the follow on from the off state. The
    /// toggle also scrolls to the current unit.
    @Test func followTurnsOnFromEachState() async throws {
        let (model, studio, _, pane) = try await scrolling("on")
        let follow = model.transcriptFollow
        let height = try #require(pane.enclosingScrollView).contentView.bounds.height
        let frame = try unit(300, in: pane).frames.lowerBound
        await seek(studio, to: frame)
        model.transcriptTick(frame: frame)

        let wheel = try scrollWheel(-5)
        func off() {
            pane.scrollWheel(with: wheel)
            #expect(!follow.isOn)
        }
        off()
        model.toggleTranscriptFollow()
        #expect(follow.isOn, "the toggle")
        let third = try offset(of: try unit(300, in: pane), in: pane)
        #expect(abs(third - height / 3) < 1, "the toggle scrolls to the current unit: \(third)")

        off()
        model.transport(.playStop)
        await model.settleTransport()
        #expect(follow.isOn, "a play start")
        model.transport(.playStop)
        await model.settleTransport()

        off()
        model.transport(.seek(.frame(frame)))
        await model.settleTransport()
        #expect(follow.isOn, "a seek")

        model.toggleTranscriptFollow()
        #expect(!follow.isOn, "the toggle turns the follow off")
        await model.close()
    }

    /// P4: the follow state stays through a tab change and back.
    @Test func followSurvivesATabChange() async throws {
        let (model, _, window, pane) = try await scrolling("tab")
        pane.scrollWheel(with: try scrollWheel(-5))
        try #require(!model.transcriptFollow.isOn)

        model.selectInspectorTab(.clip)
        await until("the pane goes") { self.pane(window) == nil }
        model.showTranscript()
        _ = try await waitForPane(window)
        #expect(!model.transcriptFollow.isOn, "off stays off")

        model.toggleTranscriptFollow()
        model.selectInspectorTab(.clip)
        await until("the pane goes") { self.pane(window) == nil }
        model.showTranscript()
        _ = try await waitForPane(window)
        #expect(model.transcriptFollow.isOn, "on stays on")
        await model.close()
    }

    /// P4: with the follow off, the scroll position is the same after a tab change, after Hide
    /// Inspector and Show Inspector, and after Hide Transcript and Show Transcript.
    @Test func scrollPositionSurvivesHideAndShow() async throws {
        let (model, _, window, first) = try await scrolling("position")
        first.scrollWheel(with: try scrollWheel(-20))
        try #require(!model.transcriptFollow.isOn)
        let clip = try #require(first.enclosingScrollView).contentView
        clip.scroll(to: NSPoint(x: 0, y: 600))
        let origin = first.scrollOrigin
        try #require(origin > 100, "the text scrolled: \(origin)")

        let pairs: [(String, () -> Void, () -> Void)] = [
            ("tab", { model.selectInspectorTab(.clip) }, { model.showTranscript() }),
            (
                "inspector", { model.toggleInspector() },
                {
                    model.toggleInspector()
                    model.selectInspectorTab(.transcript)
                }
            ),
            ("transcript", { model.toggleTranscript() }, { model.toggleTranscript() }),
        ]
        for (name, hide, show) in pairs {
            hide()
            await until("the pane goes after \(name)") { self.pane(window) == nil }
            show()
            let pane = try await waitForPane(window, focused: false)
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(abs(pane.scrollOrigin - origin) < 1, "\(name): \(pane.scrollOrigin) against \(origin)")
        }
        await model.close()
    }

    /// P18: the check mark of the View item equals the follow state after a user scroll, the
    /// toggle, the item, a play start, and a seek. The check box of the pane reads the same
    /// property; the on-screen check shows it.
    @Test func followStateShowsInTheMenuAndThePane() async throws {
        let (model, _, _, pane) = try await scrolling("shows")
        app.key = model
        let follow = model.transcriptFollow

        func shown(_ step: String) {
            #expect(app.transcriptFollowItem.checked == follow.isOn, "the item after \(step)")
        }
        shown("the start")

        pane.scrollWheel(with: try scrollWheel(-5))
        shown("a user scroll")
        model.toggleTranscriptFollow()
        shown("the toggle")
        model.toggleTranscriptFollow()
        shown("the toggle off")
        model.transport(.playStop)
        await model.settleTransport()
        shown("a play start")
        await model.close()
    }

    /// P18: the item is on while the Transcript tab shows, with the follow on or off, and it is
    /// off with the tab hidden and with no session window. It flips the follow.
    @Test func followItemFromEachState() async throws {
        let (model, _, window, pane) = try await scrolling("item")
        app.key = model
        #expect(app.transcriptFollowItem == (true, true), "the follow on")
        pane.scrollWheel(with: try scrollWheel(-5))
        #expect(app.transcriptFollowItem == (false, true), "the follow off after a user scroll")
        model.toggleTranscriptFollow()
        #expect(app.transcriptFollowItem == (true, true), "the item turns it on")

        model.selectInspectorTab(.clip)
        #expect(!app.transcriptFollowItem.enabled, "the tab hidden")
        await until("the pane goes") { self.pane(window) == nil }
        app.key = nil
        #expect(!app.transcriptFollowItem.enabled, "no session window")
        await model.close()
    }

    /// P18: the pane follow is apart from View > Automatic Scroll.
    @Test func paneFollowIsApartFromAutomaticScroll() async throws {
        let (model, _, _, pane) = try await scrolling("apart")
        let lanes = model.timeline.follows

        model.toggleTranscriptFollow()
        pane.scrollWheel(with: try scrollWheel(-5))
        model.toggleTranscriptFollow()
        #expect(model.timeline.follows == lanes, "the pane changes do not change Automatic Scroll")

        let follow = model.transcriptFollow.isOn
        model.run(.toggleFollow)
        #expect(model.timeline.follows != lanes, "Automatic Scroll changed")
        #expect(model.transcriptFollow.isOn == follow, "and the pane follow did not")
        await model.close()
    }
}
