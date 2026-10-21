import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The Gain at Playhead field (C11): it shows the envelope of the clips of the selected tracks at
/// the playhead, a typed value sets a point there, and it is off when no clip plays the playhead.
extension InspectorTests {
    @Test func theGainAtPlayheadFieldShowsTheValueAndSetsAPoint() async throws {
        let (model, studio, window, _) = try await open(try await package())
        let chrome = try #require(model.chrome)
        var heard: [String] = []
        chrome.announce = { text, _ in heard.append(text) }
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setEnvelope([0: Gain(dB: 0)!, 40_000: Gain(dB: -16)!], clip: "A")
        }
        model.timeline.marks = overA
        await studio.perform(.seek(.frame(20_000)))
        let fields = try await paneFields(window)
        await until("the field shows the envelope") { fields[3].stringValue == decibels(-8) }

        try await type("-3", in: fields[3], window, model)
        press("\r", 36, window)

        await until("the typed value sets a point") {
            studio.session.clip("A")?.clip.envelope.points.map(\.frame) == [0, 20_000, 40_000]
        }
        #expect(studio.session.clip("A")?.clip.envelope.gain(at: 20_000) == -3)
        #expect(heard == [L10n.gainPointSet.format(decibels(-3) + " " + L10n.inspectorDecibels.text)], "\(heard)")
        #expect(undoAll(model, studio) == 2, "the setup edit and the typed point")

        await studio.perform(.seek(.frame(60_000)))
        await until("no clip plays the playhead: the field is off") { !fields[3].isEnabled }
        #expect(fields[3].stringValue.isEmpty)
        await model.close()
    }

    /// A selected track with no range has no clip fields, and Gain at Playhead shows when a clip of the
    /// track plays the playhead.
    @Test func aSelectedTrackShowsTheGainAtPlayheadAlone() async throws {
        let (model, studio, window, _) = try await open(try await package())
        await studio.perform(.seek(.frame(20_000)))
        model.timeline.marks = Marks(tracks: ["t1"])
        await until("the field shows alone") { shownFields(window).count == 1 }
        #expect(shownFields(window).first?.isEnabled == true)
        await studio.perform(.seek(.frame(60_000)))
        await until("no clip plays: no field") { shownFields(window).isEmpty }
        await model.close()
    }
}
