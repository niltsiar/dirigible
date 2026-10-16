import Foundation
import Testing
import os

@testable import DirigibleAudio

/// The start state and the stop time of a writer (decision 0030), with no HAL.
struct WriterLifecycleTests {
    /// A late attach and the abandon of a stop race from one start state: in each of 2,000 runs on
    /// two threads, exactly one wins.
    @Test func anAttachAndAnAbandonHaveOneWinner() {
        for _ in 0..<2_000 {
            let lifecycle = WriterLifecycle()
            let wins = OSAllocatedUnfairLock(initialState: 0)
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                let won = index == 0 ? lifecycle.attach() == .notAttached : lifecycle.abandon()
                if won { wins.withLock { $0 += 1 } }
            }
            #expect(wins.withLock { $0 } == 1)
        }
    }

    @Test func theFirstAttachLearnsThatItIsFirst() {
        let lifecycle = WriterLifecycle()
        #expect(lifecycle.attach() == .notAttached)
        #expect(lifecycle.attach() == .attached)
        #expect(!lifecycle.abandon(), "a stop gave up a writer that attached")
        #expect(lifecycle.state == .attached)
    }

    @Test func anAbandonedWriterRefusesALateAttach() {
        let lifecycle = WriterLifecycle()
        #expect(lifecycle.abandon())
        #expect(lifecycle.attach() == .abandoned)
        #expect(lifecycle.state == .abandoned)
    }

    @Test func theStopTimeKeepsTheLowestValue() {
        let lifecycle = WriterLifecycle()
        #expect(lifecycle.endHostNanos == .max)
        lifecycle.end(atHostNanos: 500)
        lifecycle.end(atHostNanos: 900)
        #expect(lifecycle.endHostNanos == 500)
        DispatchQueue.concurrentPerform(iterations: 64) { lifecycle.end(atHostNanos: UInt64(100 + $0)) }
        #expect(lifecycle.endHostNanos == 100)
    }
}
