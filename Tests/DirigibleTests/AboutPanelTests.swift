import Testing

@testable import DirigibleApp

/// Criterion V4: the About panel shows the source commit of the bundle after the version.
struct AboutPanelTests {
    /// Control: a function that returns `CFBundleVersion` fails the first case.
    @Test func theAboutVersionIsTheSourceCommit() {
        #expect(aboutVersion(info: ["CFBundleVersion": "1", "DirigibleCommit": "1a2b3c4-dirty"]) == "1a2b3c4-dirty")
        #expect(aboutVersion(info: ["CFBundleVersion": "1"]) == nil, "a swift run has no DirigibleCommit")
    }
}
