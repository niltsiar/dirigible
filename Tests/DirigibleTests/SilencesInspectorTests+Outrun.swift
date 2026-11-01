import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// A review that the session outran shows as out of date (decision 0066, criterion C19).
extension SilencesInspectorTests {
    /// A review shows rows, shade, and an on Apply only for a scan that matches the session: a clip
    /// move makes it out of date, an undo to the scanned state makes it current, a marker add does
    /// not change it, and the shade shows only on the Silences tab.
    @Test func aReviewThatTheSessionOutranShowsAsOutOfDate() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio) = try await open(try await package("outrun"))
        await model.findSilences()
        try #require(model.inspectorTab == .silences && model.showsInspector)
        let shade = [
            SilenceBand(silence: Self.silenceA, cut: Self.cutA), SilenceBand(silence: Self.silenceB, cut: Self.cutB),
        ]
        #expect(model.silenceBands(in: studio) == shade && model.canApplySilences, "a fresh scan")

        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setMarker(Marker(id: MarkerID(), name: "Later", position: 10_000, kind: .marker))
        }
        #expect(model.silenceBands(in: studio) == shade && model.canApplySilences, "a marker add")

        try studio.edit(ripple: false) { session throws(SessionError) in try session.move("c1", to: "t1", start: 24_000)
        }
        #expect(model.silences.isStale(in: studio), "a clip move")
        #expect(!model.canApplySilences, "Apply is on for an old scan")
        #expect(
            model.silenceBands(in: studio).isEmpty, "the shade of the old frames: \(model.silenceBands(in: studio))")

        model.undo()
        await model.settleTransport()
        #expect(!model.silences.isStale(in: studio) && model.canApplySilences, "undo to the scanned state")
        #expect(model.silenceBands(in: studio) == shade)

        model.selectInspectorTab(.clip)
        #expect(model.silenceBands(in: studio).isEmpty, "the shade shows on another tab")
        await model.close()
    }
}
