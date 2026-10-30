import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Transcript criterion P13: the main-actor part of one build and apply of the pane text for a 2 h
/// session of 2 tracks and 27 000 units takes 50 ms p90 or less over 10 runs with -O (`make bench
/// FILTER=TranscriptTextBenchmark`); 1 s in debug, a proxy. The value and its attributed text build
/// off the main actor (`Session.words()` with the root walk of the origin chain of two levels on
/// track 1, and `TranscriptText`); the time covers the storage replacement and the layout of the
/// visible part at a 320 pt pane, and the report prints the off-main time apart. Each run swaps
/// between two sessions that differ in their words, so each run replaces the storage.
@MainActor struct TranscriptTextBenchmark {
    #if DEBUG
        static let budget = Duration.seconds(1)
    #else
        static let budget = Duration.milliseconds(50)
    #endif
    static let frames = Frames(345_600_000)

    /// 13 500 words over 6 750 s; a 2 s pause after each 40 words makes a paragraph.
    static func transcript() throws -> TranscriptFile {
        let words = (0..<13_500).map { word in
            let start = Double(word) * 0.45 + Double(word / 40) * 2
            return #"{"word":"word\#(word % 97)","start":\#(start),"end":\#(start + 0.4)}"#
        }
        return try TranscriptFile(data: Data(#"{"words":[\#(words.joined(separator: ","))]}"#.utf8))
    }

    /// 13 500 words on each of two tracks over 6 750 s of a 7 200 s file; a 2 s pause after each
    /// 40 words makes a paragraph. The second session ends the clip of track 2 at 6 000 s.
    static func sessions() throws -> (full: Session, trimmed: Session) {
        var session = Session(sampleRate: 48_000)
        for n in 1...2 {
            let (file, track, clip) = (FileID("h\(n)"), TrackID("t\(n)"), ClipID("A\(n)"))
            try session.addFile(AudioFile(id: file, path: "h\(n).wav", layout: .mono, length: frames))
            try session.addTrack(track, name: "Speaker \(n)", layout: .mono)
            try session.place(Clip(id: clip, file: file, start: 0, offset: 0, length: frames), on: track)
            try session.importTranscript(try Self.transcript(), name: "Speaker \(n)", track: track, at: 0)
        }
        let noise = Treatment(.noise(.standard))
        for stem in ["h1 NR", "h1 NR NR"] {
            let runs = try session.clipRuns(of: ["A1"]).map {
                RenderedRun(run: $0, stem: stem, treatment: noise, addedGain: .zero)
            }
            _ = try session.repoint(runs)
        }
        var trimmed = session
        try trimmed.trim("A2", to: 0..<Frames(6_000 * 48_000))
        return (session, trimmed)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aBuildAndApplyOfTwentySevenThousandUnitsFitsFiftyMilliseconds() async throws {
        let (full, trimmed) = try Self.sessions()
        #expect(full.words().count == 27_000, "\(full.words().count) words")
        #expect(full.files["h1 NR NR"]?.origin?.source == "h1 NR", "the chain has two levels")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 600), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let scroll = TranscriptTextView.scrollView()
        scroll.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(scroll)
        window.orderFront(nil)
        let text = try #require(scroll.documentView as? TranscriptTextView)

        var times: [Duration] = []
        var builds: [Duration] = []
        var unchanged: [Int] = []
        for run in 0...10 {
            let replacements = text.replacements
            let session = run.isMultiple(of: 2) ? full : trimmed
            #expect(text.begin(revision: run + 1))
            let off = ContinuousClock.now
            let built = await TranscriptTextView.build(session, notices: [], revision: run + 1)
            let build = ContinuousClock.now - off
            let start = ContinuousClock.now
            Self.timedSpan(text, built, scroll)
            let time = ContinuousClock.now - start
            if text.replacements != replacements + 1 { unchanged.append(run) }
            // Run 0 builds the first layout and is not timed.
            if run > 0 { (times, builds) = (times + [time], builds + [build]) }
        }
        #expect(unchanged.isEmpty, "runs that replaced no storage: \(unchanged)")
        let p90 = times.sorted()[8]
        print(
            "bench report: TranscriptTextBenchmark main-actor apply p90 \(p90), off-main build p90 \(builds.sorted()[8]), "
                + "runs \(times.sorted())")
        expectWithinBudget(p90, Self.budget, "main-actor apply of 27 000 units p90 \(p90)")
        window.close()
    }

    /// The timed span of one run, as one frame for a trace
    /// (`scripts/bench.sh --trace <file> --under timedSpan`).
    @inline(never)
    static func timedSpan(_ text: TranscriptTextView, _ built: TranscriptTextView.Built, _ scroll: NSScrollView) {
        text.apply(built)
        scroll.window?.contentView?.layoutSubtreeIfNeeded()
        text.textLayoutManager?.textViewportLayoutController.layoutViewport()
        scroll.displayIfNeeded()
    }

    // MARK: Selection (P7 to P9, P16)

    #if DEBUG
        static let selectionBudget = Duration.milliseconds(300)
    #else
        static let selectionBudget = Duration.milliseconds(16)
    #endif

    /// A package of the session of `transcript()` on two tracks: 27 000 units.
    static func package(in folder: TemporaryFolder) async throws -> URL {
        let url = folder.url.appending(path: "big.dirigible")
        var session = Session(sampleRate: 48_000)
        for n in 1...2 {
            let (file, track) = ("f\(n)", TrackID("t\(n)"))
            try session.addFile(AudioFile(id: FileID(file), path: file + ".wav", layout: .mono, length: frames))
            try session.addTrack(track, name: "Speaker \(n)", layout: .mono)
            try session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: track)
            try session.place(
                Clip(id: ClipID(file), file: FileID(file), start: 0, offset: 0, length: frames), on: track)
            try session.importTranscript(try Self.transcript(), name: "Speaker \(n)", track: track, at: 0)
        }
        let written = session
        try await Task.detached {
            try Session.create(at: url, sampleRate: 48_000)
            try written.write(to: url)
        }.value
        return url
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    static func p90(_ values: [Double]) -> Double { values.sorted()[values.count * 9 / 10] }

    /// One selection change at 27 000 units takes 16 ms p90 or less with -O: a drag step (the pane
    /// write while the mouse is down, then the show of the timeline selection that tints the range)
    /// over 200 steps that widen the range from unit 1 000 to the last unit, and a Shift-Right
    /// word move over 50 steps from a range of 40 units. The report prints the time of the layout and
    /// display after each change apart, the moves from a range of 12 000 units (AppKit sets a
    /// selection in time that grows with its length), and the time of Select All, which have no
    /// budget.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aSelectionChangeOfTwentySevenThousandUnitsFitsSixteenMilliseconds() async throws {
        let base = try TranscriptPaneTests()
        let (model, _, window, _) = try await base.open(try await Self.package(in: base.folder))
        model.showTranscript()
        let pane = try await base.waitForPane(window)
        let text = try #require(pane.shown?.text)
        #expect(text.units.count == 27_000, "\(text.units.count) units")
        func draw() {
            window.contentView?.layoutSubtreeIfNeeded()
            pane.textLayoutManager?.textViewportLayoutController.layoutViewport()
            pane.displayIfNeeded()
        }

        let anchor = text.units[1_000].text.lowerBound + pane.noticeLength
        var (drag, dragDraw) = ([Double](), [Double]())
        let count = 200
        for step in 1...count {
            let unit = 1_000 + (text.units.count - 1_000) * step / count - 1
            let end = text.units[unit].text.upperBound + pane.noticeLength
            let start = ContinuousClock.now
            pane.setSelectedRanges(
                [NSValue(range: NSRange(location: anchor, length: end - anchor))], affinity: .downstream,
                stillSelecting: step < count)
            pane.show(model.timeline.selection)
            let shown = ContinuousClock.now
            draw()
            (drag, dragDraw) = (drag + [Self.milliseconds(shown - start)], dragDraw + [Self.milliseconds(.now - shown)])
        }
        #expect(pane.selectedRange().length == text.units[26_999].text.upperBound - text.units[1_000].text.lowerBound)

        /// `count` Shift-Right moves from a selection of `size` units that starts at unit 1 000.
        func shiftRight(from size: Int, count: Int) -> (step: [Double], draw: [Double]) {
            let first = text.units[1_000].text.lowerBound + pane.noticeLength
            pane.setSelectedRange(NSRange(location: first, length: 0))
            pane.setSelectedRange(
                NSRange(location: first, length: text.units[999 + size].text.upperBound + pane.noticeLength - first))
            pane.show(model.timeline.selection)
            draw()
            var (step, drawn) = ([Double](), [Double]())
            for _ in 1...count {
                let start = ContinuousClock.now
                pane.moveSelectionEnd(by: 1)
                pane.show(model.timeline.selection)
                let shown = ContinuousClock.now
                draw()
                (step, drawn) = (step + [Self.milliseconds(shown - start)], drawn + [Self.milliseconds(.now - shown)])
            }
            return (step, drawn)
        }
        let moves = shiftRight(from: 40, count: 50)
        let wide = shiftRight(from: 12_000, count: 10)

        model.timeline.selection = .none
        pane.show(.none)
        let all = ContinuousClock.now
        model.run(.selectAll)
        pane.show(model.timeline.selection)
        let allTime = Self.milliseconds(.now - all)
        print(
            "bench report: TranscriptTextBenchmark selection change over \(text.units.count) units: "
                + "drag step p90 \(Self.p90(drag)) ms (max \(drag.max() ?? 0), draw p90 \(Self.p90(dragDraw))), "
                + "Shift-Right move from 40 units p90 \(Self.p90(moves.step)) ms (max \(moves.step.max() ?? 0), "
                + "draw p90 \(Self.p90(moves.draw))), from 12 000 units p90 \(Self.p90(wide.step)) ms "
                + "(max \(wide.step.max() ?? 0), draw p90 \(Self.p90(wide.draw))), "
                + "Select All \(allTime) ms")
        let budget = Self.selectionBudget
        expectWithinBudget(
            .milliseconds(Self.p90(drag)), budget, "drag step at 27 000 units p90 \(Self.p90(drag)) ms")
        expectWithinBudget(
            .milliseconds(Self.p90(moves.step)), budget,
            "Shift-Right move at 27 000 units p90 \(Self.p90(moves.step)) ms")
        window.close()
    }
}
