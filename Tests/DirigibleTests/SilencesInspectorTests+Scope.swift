import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// A row click never changes the scope of the next scan (decision 0066, criteria C5b, C21).
extension SilencesInspectorTests {
    /// A row click never changes the scope of the next scan: a scan of the whole session stays
    /// whole, and a scan of a range keeps its range. A range that the user sets after the click is
    /// the new scope.
    @Test func scanAgainAfterARowClickKeepsTheScope() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _) = try await open(try await package())
        await model.scanSilences()
        try #require(rows(model).map(\.silence) == [Self.silenceA, Self.silenceB])
        model.selectSilences([1])
        model.silences.settings.threshold = -39
        await model.scanSilences()
        #expect(
            model.silences.review?.scan.range == 0..<480_000, "the scope: \(String(describing: model.silences.review))")
        #expect(
            rows(model).map(\.silence) == [Self.silenceA, Self.silenceB], "the clicked silence only: \(rows(model))")

        model.silences.review = nil
        model.timeline.selection = .range(Marks(inPoint: 100_000, outPoint: 150_000, tracks: ["t1"]))
        await model.scanSilences()
        try #require(rows(model).map(\.silence) == [Self.silenceA])
        model.selectSilences([0])
        model.silences.settings.threshold = -38
        await model.scanSilences()
        #expect(model.silences.review?.scan.range == 100_000..<150_000, "the range of the first scan")

        model.selectSilences([0])
        model.timeline.selection = .range(Marks(inPoint: 300_000, outPoint: 350_000, tracks: ["t1"]))
        await model.scanSilences()
        #expect(model.silences.review?.scan.range == 300_000..<350_000, "a range that the user set")
        #expect(rows(model).map(\.silence) == [Self.silenceB], "\(rows(model))")
        model.timeline.selection = .none
        await model.scanSilences()
        #expect(model.silences.review?.scan.range == 0..<480_000, "no range scans the whole session")
        await model.close()
    }
}
