import Foundation
import Testing

/// The last check of `until`. A stall past the limit can queue a main-queue job behind the poll
/// that ends the stall. An example is the retry of a refused draw (`TimelineDocumentView`). The
/// wait gives that job one more turn before it records the issue. The cases hold the main thread,
/// so they run one at a time.
@Suite(.serialized) @MainActor struct UntilTests {
    /// The poll sleeps 10 ms. The job is due at 25 ms. The hold takes the main thread for 60 ms.
    /// Both timers fire during the hold, so the sleep resume enters the main queue before the job.
    /// The resume then sees the clock past the 30 ms limit.
    @Test func aJobThatAStallQueuedRunsBeforeTheLastCheck() async {
        var done = false
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) { done = true }
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: 0.06) }
        await until(limit: .milliseconds(30), "the job that the stall queued did not run") { done }
    }

    @Test func aConditionThatStaysFalseRecordsTheMessage() async {
        await withKnownIssue {
            await until(limit: .milliseconds(50), "the condition stayed false") { false }
        } matching: { issue in
            issue.description.contains("the condition stayed false")
        }
    }
}
