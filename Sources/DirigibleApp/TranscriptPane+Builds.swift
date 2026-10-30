import AppKit
import DirigibleCore

/// The build queue of the Transcript pane (P13). At most one build runs, and the last build is of
/// the newest revision: a revision that arrives during a build waits and replaces an older
/// waiting one.
struct TranscriptBuilds {
    /// The input of one build.
    struct Request {
        let session: Session
        let notices: [String]
        let revision: Int
    }

    private var running = false
    private var waiting: Request?

    /// The revision that waits for the running build, if any.
    var waitingRevision: Int? { waiting?.revision }

    /// A new `request`. Returns it when the pane must start it now. Else it waits.
    mutating func submit(_ request: Request) -> Request? {
        guard running else {
            running = true
            return request
        }
        waiting = request
        return nil
    }

    /// The running build of `revision` ended. Returns the waiting request when its revision is
    /// newer, so the pane drops the result and builds it. Returns nil when the pane applies the
    /// result.
    mutating func finish(revision: Int) -> Request? {
        running = false
        defer { waiting = nil }
        guard let next = waiting, next.revision != revision else { return nil }
        running = true
        return next
    }
}

extension TranscriptTextView {
    /// A value built off the main actor for the session revision `revision`.
    struct Built {
        let revision: Int
        let shown: Shown
        let attributed: NSAttributedString
    }
}
