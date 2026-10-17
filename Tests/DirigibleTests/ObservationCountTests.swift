import Observation
import Testing

@Observable @MainActor final class CountedBox {
    var x = 0
    var y = 0
}

/// Run 2026-10-16-observation-hang C5: the registration counter of the meter-rate tests counts
/// the live registrations of each key path, and a false registrar layout gives an issue, not a
/// count or a crash.
@MainActor struct ObservationCountTests {
    @Test func countsAKnownTracking() throws {
        let box = CountedBox()
        for _ in 0..<2 {
            withObservationTracking {
                _ = box.x
            } onChange: {
            }
        }
        withObservationTracking {
            _ = box.y
        } onChange: {
        }
        let before = try #require(registrations(of: box))
        #expect(
            before.made(since: 0) == [\CountedBox.x: 2, \CountedBox.y: 1] && before.live == 3 && before.next == 3,
            "3 trackings: \(before.made(since: 0)), live \(before.live), next \(before.next)")
        #expect(before.made(since: 2) == [\CountedBox.y: 1], "the tracking of y has id 2")
        box.x = 1
        let after = try #require(registrations(of: box))
        #expect(
            after.made(since: 0) == [\CountedBox.y: 1] && after.live == 1,
            "a change of x cancels its 2 trackings: \(after.made(since: 0)), live \(after.live)")
    }

    @Test func refusesAFalseLayout() {
        let counts = plainCounts(id: 3, observations: 2)
        #expect(counts?.next == 3 && counts?.live == 2, "a true layout: \(String(describing: counts))")
        for (id, observations) in [(-1, 0), (3, 4), (3, -1)] {
            var refused: (next: Int, live: Int)? = (0, 0)
            withKnownIssue("a false layout records an issue") {
                refused = plainCounts(id: id, observations: observations)
            } matching: { issue in
                issue.comments.contains { $0.rawValue.hasPrefix(unknownRegistrarLayout) }
            }
            #expect(refused == nil, "no count for id \(id), observations \(observations)")
        }
    }
}
