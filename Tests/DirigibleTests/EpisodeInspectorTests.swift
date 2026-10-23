import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The take sync lines of the Episode inspector (decision 0061, C14), with the English table.
struct EpisodeInspectorTests {
    static let english = Result { try stringsTable("en") }

    func lines(_ sync: [Int: TakeSync], fault: FinalizeError? = nil) throws -> [String] {
        let table = try Self.english.get()
        return takeSyncLines(sync, fault: fault, sampleRate: 48_000, locale: Locale(identifier: "en_US")) {
            table[$0.rawValue] ?? $0.rawValue
        }
    }

    @Test func takeSyncLineShowsEachState() throws {
        #expect(try lines([4: .inSync(offset: 240_000)]) == ["Take 4: In sync, +5.000 s"])
        #expect(try lines([4: .broken(from: 60_816_000, shifts: 2)]) == ["Take 4: Out of sync from 0:21:07, 2 shifts"])
        #expect(try lines([:]) == [], "no take audio")
        // Two takes, in take order; the tester offset rounds half away from zero to the ms.
        #expect(
            try lines([2: .inSync(offset: -1_415_798), 1: .broken(from: 60_816_000, shifts: 3)]) == [
                "Take 1: Out of sync from 0:21:07, 3 shifts", "Take 2: In sync, -29.496 s",
            ])
        let fault = FinalizeError.readFailed(file: "Capture/take4.anchor", errno: EACCES)
        #expect(
            try lines([1: .inSync(offset: 0)], fault: fault) == ["Take sync: Cannot read Capture/take4.anchor"],
            "the fault line takes the place of the state lines")
    }
}
