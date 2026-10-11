import Foundation
import Testing

@testable import DirigibleCore

/// The URL and the image of a marker in the session and in `session.xml` version 7 (run
/// 2026-10-11-chapters-in-file, criteria C1, C2).
struct MarkerFieldTests {
    let package = FileManager.default.temporaryDirectory
        .appending(path: "MarkerFieldTests-\(UUID().uuidString)/Markers.dirigible")

    static let image = "0B3C5B2E-6F1A-4D2B-9E57-1C8F2A9D4E60.png"

    static func chapter(url: String? = nil, image: String? = nil) throws -> Marker {
        Marker(
            id: "c1", name: "Intro", position: 48_000, kind: .chapter, url: try url.map(WebURL.init),
            image: try image.map(ArtworkName.init))
    }

    /// A URL of `count` ASCII bytes.
    static func url(bytes count: Int) -> String {
        let head = "https://example.com/"
        return head + String(repeating: "a", count: count - head.utf8.count)
    }

    /// The XML text of a session with `marker`, with its version attribute set to `version` and
    /// each pair of `replacing` applied.
    func xml(_ marker: Marker, version: Int, replacing: [(String, String)] = []) throws -> Data {
        var session = Session(sampleRate: 48_000)
        try session.setMarker(marker)
        try session.write(to: package)
        var text = try String(contentsOf: package.appending(path: "session.xml"), encoding: .utf8)
        text = text.replacingOccurrences(of: "version=\"\(session.fileVersion)\"", with: "version=\"\(version)\"")
        for (old, new) in replacing { text = text.replacingOccurrences(of: old, with: new) }
        return Data(text.utf8)
    }

    @Test func aChapterURLAndImageRoundTripThroughSessionXML() throws {
        let marker = try Self.chapter(url: "https://example.com/a?b=1&c=<2>", image: Self.image)
        var session = Session(sampleRate: 48_000)
        try session.setMarker(marker)
        try session.setMarker(Marker(id: "m1", name: "Plain", position: 0, kind: .marker))

        try session.write(to: package)
        let read = try Session(contentsOf: package)

        #expect(read.markers["c1"] == marker, "read back: \(String(describing: read.markers["c1"]))")
        #expect(read == session)
        let text = try String(contentsOf: package.appending(path: "session.xml"), encoding: .utf8)
        #expect(text.contains("version=\"7\""), "the version")
        let plain = text.split(separator: "\n").first { $0.contains("id=\"m1\"") } ?? ""
        #expect(!plain.contains("url=") && !plain.contains("image="), "a marker with neither: \(plain)")
    }

    @Test func eachFieldAloneGivesSevenAndNeitherKeepsTheVersion() throws {
        var session = Session(sampleRate: 48_000)
        #expect(session.fileVersion == 1)
        var episode = Episode()
        episode.explicit = true
        session.setEpisode(episode)
        try session.setMarker(Marker(id: "m1", name: "Plain", position: 0, kind: .chapter))
        #expect(session.fileVersion == 6, "episode data and a bare marker")
        try session.setMarker(try Self.chapter(url: "https://example.com"))
        #expect(session.fileVersion == 7, "only a URL")
        try session.setMarker(try Self.chapter(image: Self.image))
        #expect(session.fileVersion == 7, "only an image")
        try session.setMarker(try Self.chapter())
        #expect(session.fileVersion == 6, "neither")
    }

    @Test func theReaderRefusesAFieldBeforeVersionSeven() throws {
        let url = try Self.chapter(url: "https://example.com")
        let image = try Self.chapter(image: Self.image)
        #expect(throws: SessionFileError.invalidValue(element: "marker", attribute: "url")) {
            try Session(xml: try xml(url, version: 6))
        }
        #expect(throws: SessionFileError.invalidValue(element: "marker", attribute: "image")) {
            try Session(xml: try xml(image, version: 6))
        }
        #expect(throws: SessionFileError.unsupportedVersion(7)) {
            try Session(xml: try xml(url, version: 7), newest: 6)
        }
        #expect(try Session(xml: try xml(url, version: 7)).markers["c1"] == url)
        #expect(try Session(xml: try xml(image, version: 7)).markers["c1"] == image)
    }

    @Test func theReaderRefusesABadURLOrImage() throws {
        let marker = try Self.chapter(url: "https://example.com", image: Self.image)
        #expect(throws: SessionFileError.invalidValue(element: "marker", attribute: "url")) {
            try Session(xml: try xml(marker, version: 7, replacing: [("https://example.com", "ftp://a.b")]))
        }
        #expect(throws: SessionFileError.invalidValue(element: "marker", attribute: "image")) {
            try Session(xml: try xml(marker, version: 7, replacing: [(Self.image, "x.gif")]))
        }
        let long = Self.url(bytes: 256)
        #expect(throws: SessionFileError.invalidSession(.markerURLTooLong)) {
            try Session(xml: try xml(marker, version: 7, replacing: [("https://example.com", long)]))
        }
    }

    @Test func aURLOver255BytesIsRefused() throws {
        var session = Session(sampleRate: 48_000)
        let stored = try Self.chapter(url: Self.url(bytes: Marker.maximumURLBytes))
        try session.setMarker(stored)
        #expect(session.markers["c1"] == stored, "255 bytes")
        #expect(throws: SessionError.markerURLTooLong) {
            try session.setMarker(try Self.chapter(url: Self.url(bytes: Marker.maximumURLBytes + 1)))
        }
        #expect(session.markers["c1"] == stored, "the refused edit changed the marker")
    }
}
