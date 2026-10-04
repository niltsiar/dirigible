import DirigibleCore
import Foundation

/// The write chain of a studio: each package write (an autosave, a start, a finalize, or a
/// placement) runs in its turn, so the writes run one at a time in the order of their calls.
/// Only this file takes a turn or sets the wait flag.
struct SaveChain {
    fileprivate let writes = TurnQueue()
    /// True from `scheduleSave` until its write starts.
    fileprivate var waits = false

    init() {}
}

extension Studio {
    /// Runs `body` after every package write that started before this call. `body` runs in the
    /// task of the caller, so no actor hop comes between its end and the caller.
    func serialized<T>(_ body: () async -> T) async -> T { await save.writes.run(body) }

    /// Tests only: the calls that wait for their turn of the package writes.
    var writesWaiting: Int { save.writes.waiters }

    /// Writes the session off the main actor, after the previous package write. It takes its
    /// ticket now, so a later start or finalize writes after it. A save that waits for its turn
    /// writes the session of that turn, so a later call adds no write: a held Nudge key makes at
    /// most one write in progress and one that waits (decision 0018).
    func scheduleSave() {
        sendSession()
        guard !save.waits else { return }
        save.waits = true
        let (lock, write, ticket) = (lock, environment.saveSession, save.writes.ticket())
        Task {
            await save.writes.wait(for: ticket)
            save.waits = false
            saveEnded(await writeSession(session, lock: lock, previous: url, recordings: recordings, write))
            save.writes.end()
        }
    }
}
