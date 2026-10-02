import Foundation
import Testing

@testable import DirigibleApp

/// Help > Dirigible Guide opens the guide page of the app bundle one time. The repository is
/// private, so a web link would give a 404 page. `AppBundleTests` checks that the file exists.
@MainActor struct HelpTests {
    @Test func theGuideItemOpensTheGuideOfTheBundle() {
        let app = AppDelegate(recordings: nil)
        var opened: [URL] = []
        app.openURL = { opened.append($0) }

        app.openGuide()

        #expect(opened.count == 1)
        #expect(opened.first?.isFileURL == true)
        #expect(opened.first?.path.hasSuffix("Contents/Resources/Guide/guide.html") == true)
    }
}
