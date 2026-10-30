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
        try cut.rippleDelete(288_000..<336_000, on: ["t1"])
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
}
