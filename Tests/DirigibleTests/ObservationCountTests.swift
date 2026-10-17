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

    /// A fake registrar state with true plain counts (id 3, 2 live) and a pointer word that is
    /// not an object of the known layout gives an issue that names the word, and no crash.
    @Test func refusesAFakeLayout() {
        let observations = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 16)
        defer { observations.deallocate() }
        observations.storeBytes(of: 2, toByteOffset: 16, as: Int.self)
        let header = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 16)
        defer { header.deallocate() }
        header.storeBytes(of: 3, as: Int.self)
        let (box, known): (CountedBox, [AnyKeyPath: Set<Int>]) = (CountedBox(), [\CountedBox.x: [0, 1]])
        withExtendedLifetime((box, known)) {
            let storage = UInt(bitPattern: observations)
            let lookups = withUnsafeBytes(of: known) { $0.load(as: UInt.self) }
            func read(_ storage: UInt, _ lookups: UInt) -> Registrations? {
                header.storeBytes(of: storage, toByteOffset: 8, as: UInt.self)
                header.storeBytes(of: lookups, toByteOffset: 16, as: UInt.self)
                return registrations(header: header)
            }
            let count = read(storage, lookups)
            #expect(
                count?.next == 3 && count?.live == 2 && count?.ids == known,
                "the fake of a true layout gives its count: \(String(describing: count))")
            let object = UInt(bitPattern: Unmanaged.passUnretained(box).toOpaque())
            let fakes: [(storage: UInt, lookups: UInt, reason: String)] = [
                (storage, object, "lookups is not dictionary storage"),
                (0x1000, lookups, "observations at 0x1000"),
                (storage, 0x1000, "lookups at 0x1000"),
                (storage, lookups + 4, "lookups at 0x\(String(lookups + 4, radix: 16))"),
            ]
            for fake in fakes {
                var refused: Registrations? = Registrations(next: 0, live: 0, ids: [:])
                withKnownIssue("a fake layout records an issue") {
                    refused = read(fake.storage, fake.lookups)
                } matching: { issue in
                    issue.comments.contains { $0.rawValue.hasPrefix("\(unknownRegistrarLayout): \(fake.reason)") }
                }
                #expect(refused == nil, "no count for \(fake.reason)")
            }
        }
    }
}
