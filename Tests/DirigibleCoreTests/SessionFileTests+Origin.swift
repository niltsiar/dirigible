import Foundation
import Testing

@testable import DirigibleCore

/// The `<origin>` element of a file in `session.xml` (decision 0057 D9).
extension SessionFileTests {
    /// The file "a NR" sorts before its source "z", so the writer puts it first.
    func renderedBeforeSource(_ treatment: Treatment = Treatment(.noise(.standard))) throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "z", path: "z.wav", layout: .mono, length: 1_000_000))
        let origin = RenderOrigin(
            source: "z", offset: 200_000, treatment: treatment, addedGain: try #require(Gain(dB: 1.5)))
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
        case "unknown": origin.child(at: 0)?.name = "buzz"
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

    /// The `session.xml` of `session` with the `<hum>` element of the origin of "a NR" changed by
    /// `change`.
    func humDocument(_ session: Session, _ change: (XMLElement, XMLElement) -> Void) throws -> Data {
        let document = try XMLDocument(data: try session.checkedData())
        let root = try #require(document.rootElement())
        let files = try #require(root.elements(forLocalName: "files", uri: sessionNamespace).first)
        let file = try #require(
            files.elements(forLocalName: "file", uri: sessionNamespace).first {
                $0.attribute(forName: "id")?.stringValue == "a NR"
            })
        let origin = try #require(file.elements(forLocalName: "origin", uri: sessionNamespace).first)
        change(root, try #require(origin.elements(forLocalName: "hum", uri: sessionNamespace).first))
        return document.xmlData
    }

    /// C17c: a hum origin needs version 13, and the noise origin alone version 12. The hum element
    /// comes before the noise element.
    @Test func humWritesTheNextVersion() throws {
        let hum = try renderedBeforeSource(try #require(Treatment([.noise(.standard), .hum(.hz50)])))
        let noise = try renderedBeforeSource()

        let text = String(decoding: try hum.checkedData(), as: UTF8.self)
        #expect(hum.fileVersion == 13 && noise.fileVersion == 12)
        #expect(text.contains(#"version="13""#), "\(text)")
        let hum50 = try #require(text.range(of: #"<hum hz="50""#), "\(text)")
        let noise12 = try #require(text.range(of: #"<noise decibels="12""#), "\(text)")
        #expect(hum50.lowerBound < noise12.lowerBound, "\(text)")
    }

    /// C17c: a `<hum>` in a file of version 12, the version before hum, is refused, with the reason.
    @Test func humInAnOlderVersionRefused() throws {
        let data = try humDocument(try renderedBeforeSource(Treatment(.hum(.hz50)))) { root, _ in
            root.attribute(forName: "version")?.stringValue = "12"
        }
        #expect(throws: SessionFileError.invalidValue(element: "hum", attribute: "version")) {
            try Session(xml: data)
        }
    }

    /// C17c: `hz` other than 50 and 60 is refused, with the reason; 50 and 60 read.
    @Test(arguments: ["55", "0", "abc"])
    func humOtherHertzRefused(hertz: String) throws {
        let data = try humDocument(try renderedBeforeSource(Treatment(.hum(.hz50)))) { _, hum in
            hum.attribute(forName: "hz")?.stringValue = hertz
        }
        #expect(throws: SessionFileError.self) { try Session(xml: data) }
        if Int(hertz) != nil {
            #expect(throws: SessionFileError.invalidValue(element: "hum", attribute: "hz")) { try Session(xml: data) }
        }
    }

    /// C17c: each hum, alone and with each noise amount, saves and opens to the equal session.
    @Test func humRoundTrips() throws {
        for hum in Hum.allCases {
            var treatments = [Treatment(.hum(hum))]
            for decibels in NoiseReduction.range {
                let noise = try #require(NoiseReduction(decibels: decibels))
                treatments.append(try #require(Treatment([.hum(hum), .noise(noise)])))
            }
            for treatment in treatments {
                let session = try renderedBeforeSource(treatment)
                #expect(try Session(xml: try session.checkedData()) == session, "\(treatment)")
            }
        }
    }
}
