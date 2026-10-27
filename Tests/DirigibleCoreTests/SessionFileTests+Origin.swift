import Foundation
import Testing

@testable import DirigibleCore

/// The `<origin>` element of a file in `session.xml` (decision 0057 D9).
extension SessionFileTests {
    /// The file "a NR" sorts before its source "z", so the writer puts it first.
    func renderedBeforeSource() throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "z", path: "z.wav", layout: .mono, length: 1_000_000))
        let origin = RenderOrigin(
            source: "z", offset: 200_000, treatment: Treatment(.noise(.standard)),
            addedGain: try #require(Gain(dB: 1.5)))
        try session.addFile(AudioFile(id: "a NR", path: "a NR.wav", layout: .mono, length: 300_000, origin: origin))
        return session
    }

    /// C9. The reader sets the origins after all files, so a file before its source reads back equal.
    @Test func aFileBeforeItsSourceReads() throws {
        let session = try renderedBeforeSource()
        let text = String(decoding: try session.checkedData(), as: UTF8.self)
        let index = { (id: String) in text.range(of: "id=\"\(id)\"")?.lowerBound ?? text.endIndex }
        #expect(index("a NR") < index("z"), "the fixture writes the rendered file first")
        #expect(text.contains(#"<origin source="z" offset="200000" gain="1.5">"#))

        #expect(try Session(xml: Data(text.utf8)) == session)
    }

    /// C9. The reader refuses an origin in a version 11 file, a range past the source, an unknown
    /// effect element, no effect, and a cycle.
    @Test(arguments: ["version 11", "range", "unknown", "empty", "cycle"])
    func originRefusals(change: String) throws {
        let document = try XMLDocument(data: try renderedBeforeSource().checkedData())
        let root = try #require(document.rootElement())
        let files = try #require(root.elements(forLocalName: "files", uri: sessionNamespace).first)
        let byID = { (id: String) in
            files.elements(forLocalName: "file", uri: sessionNamespace).first {
                $0.attribute(forName: "id")?.stringValue == id
            }
        }
        let origin = try #require(byID("a NR")?.elements(forLocalName: "origin", uri: sessionNamespace).first)
        switch change {
        case "version 11": root.attribute(forName: "version")?.stringValue = "11"
        case "range": origin.attribute(forName: "offset")?.stringValue = "800000"
        case "unknown": origin.child(at: 0)?.name = "hum"
        case "empty": origin.setChildren(nil)
        default:
            // Two files of one length at offset 0, so only the cycle rule refuses them.
            origin.attribute(forName: "offset")?.stringValue = "0"
            try #require(byID("z")).attribute(forName: "length")?.stringValue = "300000"
            let back = try #require(origin.copy() as? XMLElement)
            back.attribute(forName: "source")?.stringValue = "a NR"
            back.attribute(forName: "offset")?.stringValue = "0"
            try #require(byID("z")).addChild(back)
        }
        #expect(throws: SessionFileError.self) { try Session(xml: document.xmlData) }
    }
}
