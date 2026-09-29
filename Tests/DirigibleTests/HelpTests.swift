import Foundation
import Testing

@testable import DirigibleApp

/// Readme-guide criterion C13: Help > Dirigible Guide opens the user guide on GitHub once.
@MainActor struct HelpTests {
    @Test func theGuideItemOpensTheGuideOnGitHub() {
        let app = AppDelegate(recordings: nil)
        var opened: [String] = []
        app.openURL = { opened.append($0.absoluteString) }

        app.openGuide()

        #expect(opened == ["https://github.com/niltsiar/dirigible/blob/main/docs/guide.md"])
    }
}
