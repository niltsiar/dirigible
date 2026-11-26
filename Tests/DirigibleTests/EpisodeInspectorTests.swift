import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The take sync lines of the Episode inspector (decision 0061, C14), with the English table.
struct EpisodeInspectorTests {
    static let english = Result { try stringsTable("en") }

    func lines(_ sync: [Int: TakeSync], faults: [FinalizeError] = []) throws -> [String] {
        let table = try Self.english.get()
        return takeSyncLines(sync, faults: faults, sampleRate: 48_000, locale: Locale(identifier: "en_US")) {
            table[$0.rawValue] ?? $0.rawValue
        }
    }

    @Test func takeSyncLineShowsEachState() throws {
        #expect(try lines([4: .inSync(offset: 240_000)]) == ["Take 4: in sync, +5.000 s"])
        #expect(
            try lines([4: .broken(from: 60_816_000, shifts: 2)]) == [
                "Take 4: out of sync from 0:21:07 on the timeline, 2 shifts"
            ])
        #expect(try lines([:]) == [], "no take audio")
        // Two takes, in take order; the tester offset rounds half away from zero to the ms.
        #expect(
            try lines([2: .inSync(offset: -1_415_798), 1: .broken(from: 60_816_000, shifts: 3)]) == [
                "Take 1: out of sync from 0:21:07 on the timeline, 3 shifts", "Take 2: in sync, -29.496 s",
            ])
        // A fault keeps out only its own take: the state lines stay, then one line for each fault.
        let take3 = FinalizeError.readFailed(file: "Capture/take3.anchor", errno: EACCES)
        let take4 = FinalizeError.readFailed(file: "Capture/take4.anchor", errno: EIO)
        #expect(
            try lines([1: .inSync(offset: 0), 2: .broken(from: 60_816_000, shifts: 2)], faults: [take3, take4]) == [
                "Take 1: in sync, +0.000 s", "Take 2: out of sync from 0:21:07 on the timeline, 2 shifts",
                "Take sync: can't read Capture/take3.anchor", "Take sync: can't read Capture/take4.anchor",
            ])
    }
}
