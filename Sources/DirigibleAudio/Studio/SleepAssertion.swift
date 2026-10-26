import Foundation
import IOKit.pwr_mgt

/// A latency-critical `ProcessInfo` activity for the life of the value, so App Nap does not slow
/// the drain of a hidden app (decisions 0014 and 0015). It lets the system sleep (probe P3).
package final class LatencyActivity: Sendable {
    /// `ProcessInfo` gives an `NSObjectProtocol` token that is only passed back to `endActivity`.
    nonisolated(unsafe) private let activity: any NSObjectProtocol

    package init(reason: String) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: reason)
    }

    deinit { ProcessInfo.processInfo.endActivity(activity) }
}

/// `kIOPMAssertPreventUserIdleSystemSleep` for the life of the value (decision 0004). A refused
/// assertion gives no ID, and the take goes on without it. It also holds a latency activity
/// (decision 0014), so the IOPM assertion stays the only sleep assertion (probe P3).
final class SleepAssertion: Sendable {
    /// The reason of the activity. It is not the name of the IOPM assertion, so a test can tell
    /// them apart.
    static let activityReason = "Dirigible records a take"
    let id: IOPMAssertionID?
    private let activity = LatencyActivity(reason: activityReason)

    init() {
        var id = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Dirigible is recording" as CFString, &id)
        self.id = status == kIOReturnSuccess ? id : nil
    }

    deinit {
        if let id { IOPMAssertionRelease(id) }
    }
}
