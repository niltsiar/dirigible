import Foundation
import Testing

@testable import DirigibleCore

/// The `<drift>` element of a file in `session.xml` (decision 0077 D4, criteria D10 and D11 of run
/// `2026-11-19-waveform-drift`).
extension SessionFileTests {
    /// A 48 kHz session with the plain file "guest" (28 800 000 frames, mono), the take file "take",
    /// the rendered file "guest NR", and the drift-corrected files "guest drift" and "guest drift 2"
    /// of "guest" (28 700 000 frames, offset 48 000, `ratio`, +3.01 dB). A clip on track "t" plays
    /// "guest drift".
    func driftSession(ratio: Double = 1 / (1 + 50e-6)) throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addCapture(
            Capture(
                id: CaptureID("take"), deviceUID: "mic", deviceName: "Mic", hostTimeNanos: 0, sampleTime: 0,
                nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0))
        try session.addFile(AudioFile(id: "guest", path: "guest.wav", layout: .mono, length: 28_800_000))
        try session.addFile(
            AudioFile(id: "take", path: "take.wav", layout: .mono, length: 28_800_000, capture: CaptureID("take")))
        let noise = RenderOrigin(source: "guest", offset: 0, treatment: Treatment(.noise(.standard)), addedGain: .zero)
        try session.addFile(
            AudioFile(id: "guest NR", path: "guest NR.wav", layout: .mono, length: 28_800_000, origin: noise))
        let link = DriftOrigin(
            source: "guest", offset: 48_000, ratio: try #require(DriftRatio(ratio)),
            addedGain: try #require(Gain(dB: 3.01)))
        for id in ["guest drift", "guest drift 2"] {
            try session.addFile(
                AudioFile(id: FileID(id), path: "\(id).wav", layout: .mono, length: 28_700_000, drift: link))
        }
        try session.addTrack("t", name: "Guest", layout: .mono)
        try session.place(Clip(id: "c", file: "guest drift", start: 0, offset: 0, length: 48_000), on: "t")
        return session
    }

    /// D10: the ratio and the gain of a drift link read back bit for bit, in a file of version
    /// `driftSessionVersion`, the next version after the voice match.
    @Test(arguments: [1 / (1 + 50e-6), 1 / (1 - 135e-6)])
    func aDriftLinkReadsBackBitForBit(ratio: Double) throws {
        let session = try driftSession(ratio: ratio)
        let data = try session.checkedData()
        let text = String(decoding: data, as: UTF8.self)

        let read = try Session(xml: data)

        #expect(driftSessionVersion == matchSessionVersion + 1 && sessionVersion == driftSessionVersion)
        #expect(text.contains(#"version="19""#), "\(text)")
        #expect(text.contains(#"<drift source="guest" offset="48000" ratio=""#) && text.contains(#"gain="3.01""#))
        let link = try #require(read.files["guest drift"]?.drift)
        #expect(link.ratio.value.bitPattern == ratio.bitPattern, "\(link.ratio.value) for \(ratio)")
        #expect(link.addedGain.dB == 3.01 && link.source == "guest" && link.offset == 48_000)
        #expect(read == session)
    }

    /// D10 and 0024 P6: a session with only a fade writes version 3 and no `<drift>`. The same
    /// session with a drift-corrected file writes `driftSessionVersion`.
    @Test func aSessionWithNoDriftLinkKeepsItsVersion() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "guest", path: "guest.wav", layout: .mono, length: 28_800_000))
        try session.addTrack("t", name: "Guest", layout: .mono)
        try session.place(Clip(id: "c", file: "guest", start: 0, offset: 0, length: 48_000), on: "t")
        try session.setFades(["c": try #require(Fades(fadeIn: 480, fadeOut: 0))])
        var drifted = session
        let link = DriftOrigin(
            source: "guest", offset: 0, ratio: try #require(DriftRatio(1 / (1 + 50e-6))), addedGain: .zero)
        try drifted.addFile(AudioFile(id: "g2", path: "g2.wav", layout: .mono, length: 28_000_000, drift: link))

        let plain = String(decoding: try session.checkedData(), as: UTF8.self)
        let linked = String(decoding: try drifted.checkedData(), as: UTF8.self)

        #expect(session.fileVersion == 3 && plain.contains(#"version="3""#) && !plain.contains("drift"), "\(plain)")
        #expect(drifted.fileVersion == driftSessionVersion && linked.contains(#"version="19""#), "\(linked)")
        #expect(linked.contains("<drift "))
    }

    /// The refusal of each D11 input: nil for a changed file that reads.
    static let driftRefusals: [String: SessionFileError?] = [
        "version 18": .invalidValue(element: "drift", attribute: "version"),
        "two elements": .invalidValue(element: "drift", attribute: "count"),
        "origin and drift": .invalidSession(.invalidOrigin("guest drift")),
        "unknown source": .invalidSession(.invalidOrigin("guest drift")),
        "source is the file": .invalidSession(.invalidOrigin("guest drift")),
        "source with a capture": .invalidSession(.invalidOrigin("guest drift")),
        "source with an origin": .invalidSession(.invalidOrigin("guest drift")),
        "source with a drift link": .invalidSession(.invalidOrigin("guest drift")),
        "another layout": .invalidSession(.invalidOrigin("guest drift")),
        "ratio nan": .invalidValue(element: "drift", attribute: "ratio"),
        "ratio 1.001": .invalidValue(element: "drift", attribute: "ratio"),
        "ratio 0.999": .invalidValue(element: "drift", attribute: "ratio"),
        "ratio 1.000999": nil,
        "offset -1": .invalidSession(.invalidOrigin("guest drift")),
        "offset 0": nil,
        "gain nan": .invalidValue(element: "drift", attribute: "gain"),
        "gain 96.5": .invalidValue(element: "drift", attribute: "gain"),
        "gain 96": nil,
        "last frame past the source": .invalidSession(.invalidOrigin("guest drift")),
        "last frame on the source end": nil,
    ]

    /// The `session.xml` of `driftSession()` with the `<drift>` element of "guest drift" changed
    /// by `change`, a key of `driftRefusals`.
    func driftDocument(_ change: String) throws -> Data {
        let document = try XMLDocument(data: try driftSession().checkedData())
        let root = try #require(document.rootElement())
        let files = try #require(root.elements(forLocalName: "files", uri: sessionNamespace).first)
        let file = { (id: String) in
            try #require(
                files.elements(forLocalName: "file", uri: sessionNamespace).first {
                    $0.attribute(forName: "id")?.stringValue == id
                })
        }
        let target = try file("guest drift")
        let drift = try #require(target.elements(forLocalName: "drift", uri: sessionNamespace).first)
        let set = { (name: String, value: String) in drift.attribute(forName: name)?.stringValue = value }
        // The worked example of D14: 28 802 881 frames end on the source end, one more is past it.
        let workedExample = { (length: String) in
            set("offset", "0")
            set("ratio", String(describing: 1 / 1.0001))
            target.attribute(forName: "length")?.stringValue = length
        }
        switch change {
        case "version 18": root.attribute(forName: "version")?.stringValue = "18"
        case "two elements": target.addChild(try #require(drift.copy() as? XMLElement))
        case "origin and drift":
            let origin = try file("guest NR").elements(forLocalName: "origin", uri: sessionNamespace).first
            target.addChild(try #require(origin?.copy() as? XMLElement))
        case "unknown source": set("source", "nobody")
        case "source is the file": set("source", "guest drift")
        case "source with a capture": set("source", "take")
        case "source with an origin": set("source", "guest NR")
        case "source with a drift link": set("source", "guest drift 2")
        case "another layout": target.attribute(forName: "channels")?.stringValue = "2"
        case "last frame past the source": workedExample("28802882")
        case "last frame on the source end": workedExample("28802881")
        default:
            let parts = change.split(separator: " ").map(String.init)
            try #require(parts.count == 2)
            set(parts[0], parts[1])
        }
        return document.xmlData
    }

    /// D11: the reader refuses each bad drift link with its error, and reads the same file with
    /// the fault removed.
    @Test(arguments: driftRefusals.keys.sorted())
    func eachBadDriftLinkIsRefused(change: String) throws {
        let expected = try #require(Self.driftRefusals[change])
        let data = try driftDocument(change)

        if let expected {
            #expect(throws: expected) { try Session(xml: data) }
        } else {
            let read = try Session(xml: data)
            #expect(read.files["guest drift"]?.drift != nil)
        }
    }
}
