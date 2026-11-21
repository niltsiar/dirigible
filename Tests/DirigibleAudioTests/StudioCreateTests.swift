import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// New Session in the app: `Studio.create` never replaces a path (criterion 10).
@MainActor
struct StudioCreateTests {
    let folder: TemporaryFolder
    var url: URL { folder.url.appending(path: "Show.dirigible") }

    init() throws { folder = try TemporaryFolder() }

    @Test func createOpensANewPackage() async throws {
        let studio = try await Studio.create(url, source: .rate(48_000))

        #expect(studio.session == Session(sampleRate: 48_000))
        #expect(studio.url == packageIdentity(url))
        await #expect(throws: StudioError.locked) { _ = try await Studio.open(url) }
    }

    /// Control: a package at the path stays byte-equal.
    @Test func createRefusesAPackageThatExists() async throws {
        try Session(sampleRate: 44_100).write(to: url)
        let before = try Data(contentsOf: url.appending(path: "session.xml"))

        await #expect(throws: StudioError.file(.exists)) { _ = try await Studio.create(url, source: .rate(48_000)) }

        #expect(try Data(contentsOf: url.appending(path: "session.xml")) == before)
    }
}
