import DirigibleCore
import Foundation
import os

/// The one writer of the Favorites store in an app process (decision 0081). Each add and each edit
/// runs on one serial queue, in call order, so a write of this process waits for the write before
/// it and never meets the store lock of another write of this process. `.locked` then comes only
/// from another process or from a window of the store that the user opened.
package final class FavoritesWriter: Sendable {
    package let store: URL
    private let queue = DispatchQueue(label: "dirigible.favorites.writer", qos: .utility)
    private let count = OSAllocatedUnfairLock(initialState: 0)

    package init(store: URL) { self.store = store }

    /// The writes that wait for the queue or run on it.
    package var queued: Int { count.withLock { $0 } }

    /// `Favorites.add` on the queue. `whenCancelled` gets an action that ends an add that still
    /// waits for the queue at once, with `.favoritesCopy(.cancelled)`: it then writes nothing and
    /// does not wait for the write ahead of it. An add whose turn comes after its Cancel writes
    /// nothing either.
    package func add(
        _ clipboard: Clipboard, from source: URL, named name: String, bin: BinID?, log: DiagnosticLog,
        progress: @escaping @Sendable (Double) -> Void, isCancelled: @escaping @Sendable () -> Bool,
        whenCancelled: (@escaping @Sendable () -> Void) -> Void = { _ in }
    ) async -> Result<BinItemID, StudioError> {
        let store = store
        let cancelled = Result<BinItemID, StudioError>.failure(.favoritesCopy(.cancelled))
        return await run(ending: cancelled, whenCancelled: whenCancelled) { () -> Result<BinItemID, StudioError> in
            guard !isCancelled() else { return cancelled }
            do throws(EditFailure<PasteError>) {
                return .success(
                    try Favorites.add(
                        clipboard, from: source, named: name, bin: bin, store: store, log: { log }, progress: progress,
                        isCancelled: isCancelled))
            } catch {
                return .failure(StudioError(favorites: error))
            }
        }
    }

    /// `Favorites.edit` on the queue: a rename, a remove, or a new group by ID.
    package func edit<Value: Sendable>(
        log: DiagnosticLog, _ body: @escaping @Sendable (inout Session) throws(SessionError) -> Value
    ) async -> Result<Value, StudioError> {
        let store = store
        return await run { () -> Result<Value, StudioError> in
            do throws(EditFailure<SessionError>) {
                return .success(try Favorites.edit(store: store, log: { log }, body))
            } catch {
                return .failure(StudioError(favorites: error))
            }
        }
    }

    /// Runs `work` on the queue. With `ending`, `whenCancelled` gets an action that returns `ending`
    /// at once while `work` has not started, and `work` then never runs.
    private func run<Value: Sendable>(
        ending: Value? = nil, whenCancelled: (@escaping @Sendable () -> Void) -> Void = { _ in },
        _ work: @escaping @Sendable () -> Value
    ) async -> Value {
        count.withLock { $0 += 1 }
        // True until the queue starts the work or the end action takes it, whichever is first.
        let waiting = OSAllocatedUnfairLock(initialState: true)
        @Sendable func take() -> Bool {
            waiting.withLock { first in
                defer { first = false }
                return first
            }
        }
        return await withCheckedContinuation { continuation in
            queue.async { [count] in
                let value = take() ? work() : nil
                count.withLock { $0 -= 1 }
                if let value { continuation.resume(returning: value) }
            }
            if let ending {
                whenCancelled {
                    if take() { continuation.resume(returning: ending) }
                }
            }
        }
    }
}
