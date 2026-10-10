import Foundation
import Testing

/// The last check of `until`. A stall past the limit can queue a main-queue job behind the poll
/// that ends the stall, as the retry of a refused draw (`TimelineDocumentView.updateLayer()`). The
/// wait gives that job one more turn before it records the issue. The cases hold the main thread,
/// so they run one at a time.
@Suite(.serialized) @MainActor struct UntilTests {
    /// The poll sleeps 10 ms, the job is due at 100 ms, and the hold takes the main thread for
    /// 400 ms. Both timers fire during the hold, so the sleep resume enters the main queue before
    /// the job, and the resume sees the clock past the 200 ms limit.
    @Test func aJobThatAStallQueuedRunsBeforeTheLastCheck() async {
        var done = false
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { done = true }
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: 0.4) }
        await until(limit: .milliseconds(200), "the job that the stall queued did not run") { done }
    }

    @Test func aConditionThatStaysFalseRecordsTheMessage() async {
        await withKnownIssue {
            await until(limit: .milliseconds(50), "the condition stayed false") { false }
        } matching: { issue in
            issue.description.contains("the condition stayed false")
        }
    }
}
