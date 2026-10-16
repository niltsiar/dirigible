import Testing

@testable import DirigibleAudio

/// The come-back rule of a lost writer (U18 of run record-start-hang), fed one drain tick each
/// 50 ms, with the time as a parameter.
struct ComeBackScheduleTests {
    /// The seconds of each try from a loss at 0 to `seconds`. A device-list event comes each 2 ms
    /// from 0 to `eventsUntil`; each try fails.
    static func tries(_ seconds: Double, eventsUntil: Double?) -> [Double] {
        let zero = ContinuousClock.now
        func at(_ millis: Int) -> ContinuousClock.Instant { zero + .milliseconds(millis) }
        var schedule = ComeBackSchedule(at: zero)
        var tries: [Int] = []
        for millis in stride(from: 0, through: Int(seconds * 1000), by: 2) {
            let event = eventsUntil.map { Double(millis) / 1000 <= $0 } ?? false
            let tick = millis.isMultiple(of: 50)
            if (event && schedule.event(at: at(millis))) || (tick && schedule.tick(at: at(millis))) {
                tries.append(millis)
                schedule.failed(at: at(millis))
            }
        }
        return tries.map { Double($0) / 1000 }
    }

    /// 500 events in 1 s after a loss: a try at the first event, then at the end of each window
    /// of 250 ms, 500 ms, and 1 s.
    @Test func aStormOfEventsTriesAtTheEndOfEachBackoffWindow() {
        #expect(Self.tries(2.1, eventsUntil: 1) == [0, 0.25, 0.75, 1.75])
    }

    /// With no event, a lost writer tries each 1 s from its loss.
    @Test func aLostWriterWithNoEventTriesEachSecond() {
        #expect(Self.tries(3.1, eventsUntil: nil) == [1, 2, 3])
    }

    /// A try that attached closes the window: the first event after the next loss tries at once.
    @Test func anAttachEndsTheBackoff() {
        let zero = ContinuousClock.now
        var schedule = ComeBackSchedule(at: zero)
        schedule.failed(at: zero)
        let inWindow = schedule.event(at: zero + .milliseconds(100))
        #expect(!inWindow, "an event in the window waits")
        schedule.attached()
        schedule.lost(at: zero + .milliseconds(150))
        let afterAttach = schedule.event(at: zero + .milliseconds(160))
        #expect(afterAttach, "the first event after an attach did not try")
    }
}
