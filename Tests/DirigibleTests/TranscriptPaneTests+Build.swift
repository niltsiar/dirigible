import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp

/// The off-main build of the pane text and its apply on the main actor (criterion P13).
extension TranscriptPaneTests {
    /// P13: the main actor applies an off-main build only while its revision is the newest one.
    /// An older build that ends before or after the newer build changes nothing.
    @Test func olderBuildIsDropped() async throws {
        let (model, studio, _, _) = try await open(try await package())
        let text = try #require(TranscriptTextView.scrollView().documentView as? TranscriptTextView)
        var cut = studio.session
        try cut.rippleDelete(288_000..<336_000, on: ["t1"], naming: [])
        #expect(text.begin(revision: 1))
        let older = await TranscriptTextView.build(studio.session, notices: [], revision: 1)
        #expect(text.begin(revision: 2))
        let newer = await TranscriptTextView.build(cut, notices: [], revision: 2)
        text.apply(older)
        #expect(text.replacements == 0 && text.string.isEmpty, "an older build that ends first is dropped")
        text.apply(newer)
        #expect(text.replacements == 1 && text.string.contains("Hello") && !text.string.contains("Second"))
        text.apply(older)
        #expect(text.replacements == 1 && !text.string.contains("Second"), "an older build that ends last is dropped")
        await model.close()
    }

    /// P13: at most one build runs, and the last build is of the newest revision. Revisions that
    /// arrive during a build start no build of their own; the build ends, its result is dropped,
    /// and one more build starts for the newest revision.
    @Test func revisionsDuringABuildGiveOneMoreBuild() async throws {
        let (model, studio, _, _) = try await open(try await package())
        let text = try #require(TranscriptTextView.scrollView().documentView as? TranscriptTextView)
        text.update(session: Session(sampleRate: 48_000), revision: 1)
        #expect(text.builds == 1)
        text.update(session: Session(sampleRate: 48_000), revision: 2)
        text.update(session: studio.session, revision: 3)
        text.update(session: studio.session, revision: 3)
        #expect(text.builds == 1, "no build starts while one runs")
        await until("the newest revision shows") { text.shownRevision == 3 }
        #expect(text.builds == 2, "the revisions 1 and 3 built")
        #expect(text.replacements == 1 && text.string.contains("Hello"), "the older result was dropped")
        #expect(text.builtRevision == 3)
        await model.close()
    }

    /// P4b: 100 display ticks that move the playhead to other units build nothing and replace no
    /// storage. The ticks reach the underline, so the check is not vacuous.
    @Test func ticksBuildNothing() async throws {
        let (model, _, window, _) = try await open(try await package(name: "ticks"))
        model.showTranscript()
        let pane = try await waitForPane(window)
        let (builds, replacements) = (pane.builds, pane.replacements)
        var moved = Set<String>()
        for tick in 0..<100 {
            let frame = Frames(tick * 12_000)
            model.transcriptTick(frame: frame)
            moved.insert("\(pane.underlines.map(\.frame))")
        }
        #expect(moved.count > 2, "the ticks moved the underline over \(moved.count) places")
        #expect((pane.builds, pane.replacements) == (builds, replacements), "a tick builds nothing")
        await model.close()
    }
}
