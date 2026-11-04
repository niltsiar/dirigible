/// A chain of turns on the main actor: each caller takes the next ticket and runs when `serving`
/// reaches it, so the turns run one at a time in ticket order.
@MainActor final class TurnQueue {
    /// Tests read it: the tickets taken.
    private(set) var tickets = 0
    private var serving = 0
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]

    /// Tests only: the callers that wait for their turn.
    var waiters: Int { waiting.count }

    /// Takes the next ticket now. The caller waits for it later and ends its turn.
    func ticket() -> Int {
        defer { tickets += 1 }
        return tickets
    }

    func wait(for ticket: Int) async {
        guard ticket != serving else { return }
        await withCheckedContinuation { waiting[ticket] = $0 }
    }

    func end() {
        serving += 1
        waiting.removeValue(forKey: serving)?.resume()
    }

    /// Runs `body` after every turn that took its ticket before this call. `body` runs in the
    /// task of the caller, so no actor hop comes between its end and the caller.
    func run<T>(_ body: () async -> T) async -> T {
        let ticket = ticket()
        await wait(for: ticket)
        defer { end() }
        return await body()
    }
}
