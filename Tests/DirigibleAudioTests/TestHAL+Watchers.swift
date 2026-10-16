import Foundation

@testable import DirigibleAudio

/// The device-list watchers of a `TestHAL`: each writer is held weakly, as the `WriterBox` of the
/// HAL holds it. With `postsAggregateEvents`, each tap aggregate create and destroy posts a
/// device-list event to each watcher, as the HAL does (probe P1 of run record-start-hang).
final class DeviceListWatchers: @unchecked Sendable {
    private final class Watcher {
        weak var writer: DeviceWriter?
        init(_ writer: DeviceWriter) { self.writer = writer }
    }

    private let lock = NSLock()
    private var watchers: [Int: Watcher] = [:]
    private var watches = 0
    private var aggregateEvents = false

    /// Adds a watcher. Its removal returns noErr.
    func watch(_ writer: DeviceWriter) -> Detach {
        let number = lock.withLock {
            watches += 1
            watchers[watches] = Watcher(writer)
            return watches
        }
        return { [self] in
            lock.withLock { watchers[number] = nil }
            return true
        }
    }

    func postAggregateEvents() { lock.withLock { aggregateEvents = true } }

    /// A tap aggregate was made or destroyed.
    func aggregateChanged() {
        let writers = lock.withLock { aggregateEvents ? watchers.values.compactMap(\.writer) : [] }
        for writer in writers { writer.post(.devicesChanged, from: nil) }
    }
}
