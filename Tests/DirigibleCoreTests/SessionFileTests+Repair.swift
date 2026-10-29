import Foundation
import Testing

@testable import DirigibleCore

/// The repair elements of an `<origin>` (decision 0064 D7): `<declip percent>`, `<rumble hz>`, and
/// `<deess hz decibels>`, in chain order, from version 14 on.
extension SessionFileTests {
    /// The four kinds of decision 0064 D2 that sort around `noise`, at values off the standard.
    func allRepairs() throws -> Treatment {
        let deess = try #require(DeEss(hertz: 7_250, decibels: 17))
        let rumble = try #require(Rumble(hertz: 120))
        let declip = try #require(Declip(percent: 95))
        return try #require(Treatment([.deess(deess), .noise(.standard), .rumble(rumble), .declip(declip)]))
    }

    /// The `session.xml` of `session` with the element `name` of the origin of "a NR" changed by
    /// `change`, which also gets the root.
    func repairDocument(_ session: Session, _ name: String, _ change: (XMLElement, XMLElement) -> Void) throws -> Data {
        let document = try XMLDocument(data: try session.checkedData())
        let root = try #require(document.rootElement())
        let files = try #require(root.elements(forLocalName: "files", uri: sessionNamespace).first)
        let file = try #require(
            files.elements(forLocalName: "file", uri: sessionNamespace).first {
                $0.attribute(forName: "id")?.stringValue == "a NR"
            })
        let origin = try #require(file.elements(forLocalName: "origin", uri: sessionNamespace).first)
        change(root, try #require(origin.elements(forLocalName: name, uri: sessionNamespace).first))
        return document.xmlData
    }

    /// C9: the three repair elements and the noise element save in chain order under version 14,
    /// and the file opens to the equal session. Each kind alone, at each end of its range, reads
    /// back equal too.
    @Test func repairElementsRoundTrip() throws {
        let session = try renderedBeforeSource(try allRepairs())

        let text = String(decoding: try session.checkedData(), as: UTF8.self)
        #expect(session.fileVersion == 14 && text.contains(#"version="14""#), "\(text)")
        let places = try [
            #"<declip percent="95""#, #"<rumble hz="120""#, #"<noise decibels="12""#,
            #"<deess hz="7250" decibels="17""#,
        ].map { try #require(text.range(of: $0), "\($0) in \(text)").lowerBound }
        #expect(places == places.sorted(), "chain order: declip, rumble, noise, deess")
        #expect(try Session(xml: try session.checkedData()) == session)

        let ends: [Effect] = [
            .declip(try #require(Declip(percent: 90))), .declip(try #require(Declip(percent: 100))),
            .rumble(try #require(Rumble(hertz: 20))), .rumble(try #require(Rumble(hertz: 300))),
            .deess(try #require(DeEss(hertz: 2_000, decibels: 1))),
            .deess(try #require(DeEss(hertz: 16_000, decibels: 40))),
        ]
        for effect in ends {
            let alone = try renderedBeforeSource(Treatment(effect))
            #expect(alone.fileVersion == 14, "\(effect)")
            #expect(try Session(xml: try alone.checkedData()) == alone, "\(effect)")
        }
    }

    /// C9: the standard values are the values of decision 0064 D3 to D5, and each type refuses the
    /// whole number past each end of its range.
    @Test func repairTypesRefuseEachEnd() {
        #expect(Rumble.standard.hertz == 80 && Declip.standard.percent == 99)
        #expect(DeEss.standard.hertz == 6_000 && DeEss.standard.decibels == 10)
        #expect(Rumble(hertz: 19) == nil && Rumble(hertz: 301) == nil)
        #expect(Declip(percent: 89) == nil && Declip(percent: 101) == nil)
        #expect(DeEss(hertz: 1_999, decibels: 10) == nil && DeEss(hertz: 16_001, decibels: 10) == nil)
        #expect(DeEss(hertz: 6_000, decibels: 0) == nil && DeEss(hertz: 6_000, decibels: 41) == nil)
    }

    /// C9: the reader refuses each value one past an end of its type, with the element and the
    /// attribute. Fail: a reader that takes any whole number.
    @Test(arguments: [
        ("rumble", "hz", "19"), ("rumble", "hz", "301"), ("declip", "percent", "89"), ("declip", "percent", "101"),
        ("deess", "hz", "1999"), ("deess", "hz", "16001"), ("deess", "decibels", "0"), ("deess", "decibels", "41"),
    ])
    func repairValuePastItsEndRefused(name: String, attribute: String, value: String) throws {
        let data = try repairDocument(try renderedBeforeSource(try allRepairs()), name) { _, node in
            node.attribute(forName: attribute)?.stringValue = value
        }
        #expect(throws: SessionFileError.invalidValue(element: name, attribute: attribute)) { try Session(xml: data) }
    }

    /// C9: a repair element in a file of version 13, the version before the repair kinds, is
    /// refused, with the reason. Each origin holds that one element.
    @Test(arguments: ["declip", "rumble", "deess"])
    func repairInAnOlderVersionRefused(name: String) throws {
        let effects: [String: Effect] = [
            "declip": .declip(.standard), "rumble": .rumble(.standard), "deess": .deess(.standard),
        ]
        let session = try renderedBeforeSource(Treatment(try #require(effects[name])))
        let data = try repairDocument(session, name) { root, _ in
            root.attribute(forName: "version")?.stringValue = "13"
        }
        #expect(throws: SessionFileError.invalidValue(element: name, attribute: "version")) { try Session(xml: data) }
    }
}
