import Foundation
import Testing
import os

@testable import DirigibleAudio

/// The drain priority of the journal queue (decision 0059).
extension DiagnosticLogTests {
    /// C7: the lines before the quit line drain at the QoS of the `quit()` caller, not at the
    /// `.utility` QoS of the queue, so a backlog meets the 1 s bound under load. A line block on
    /// the queue reads the priority of its thread until it rises or `quit()` returns.
    @Test func quitRaisesThePriorityOfTheQueuedLines() async throws {
        let queue = DispatchQueue(label: "test.journal.utility", qos: .utility)
        let log = DiagnosticLog.start(
            .app, folder: folder.url, version: "0.4.9", commit: "abc1234", now: date("2026-10-16T19:20:00Z"),
            queue: queue)
        let drain = OSAllocatedUnfairLock(initialState: (started: false, raised: false, returned: false))
        queue.async {
            let start = threadPriority()
            drain.withLock { $0.started = true }
            var raised = false
            while !raised, !drain.withLock({ $0.returned }) {
                let now = threadPriority()
                raised = now.base > start.base || now.current > start.current
            }
            drain.withLock { [raised] in $0.raised = raised }
        }
        try await poll("the line block did not start") { drain.withLock { $0.started } }
        let quitter = Thread {
            log.quit()
            drain.withLock { $0.returned = true }
        }
        quitter.qualityOfService = .userInitiated
        quitter.start()
        try await poll("quit() did not return") { drain.withLock { $0.returned } }

        #expect(drain.withLock { $0.raised }, "the queued lines drained at .utility while quit() waited")
    }

    /// C8: a `hang` line and a `fault` line drain at user-interactive QoS behind the lines
    /// before them, so they never wait for the `.utility` queue under load. A line block on the
    /// queue reads the priority of its thread until it rises, at most 5 s.
    @Test(arguments: [false, true]) func aHangOrFaultLineRaisesThePriorityOfTheQueuedLines(fault: Bool) async throws {
        let queue = DispatchQueue(label: "test.journal.utility", qos: .utility)
        let log = DiagnosticLog.start(
            .app, folder: folder.url, version: "0.4.9", commit: "abc1234", now: date("2026-10-16T19:20:00Z"),
            queue: queue)
        let drain = OSAllocatedUnfairLock(initialState: (started: false, raised: false, done: false))
        queue.async {
            let start = threadPriority()
            drain.withLock { $0.started = true }
            let deadline = ContinuousClock.now + .seconds(5)
            var raised = false
            while !raised, ContinuousClock.now < deadline {
                let now = threadPriority()
                raised = now.base > start.base || now.current > start.current
            }
            drain.withLock { [raised] in
                $0.raised = raised
                $0.done = true
            }
        }
        try await poll("the line block did not start") { drain.withLock { $0.started } }
        log.note(.take, "start-request")
        // The watchdog queue is user-interactive, and the main thread notes the fault lines.
        let noter = Thread {
            if fault { log.note(.device, "lost", level: .fault) } else { log.note(.hang, "start") }
        }
        noter.qualityOfService = .userInteractive
        noter.start()
        try await poll("the line block did not end") { drain.withLock { $0.done } }
        log.drain()

        let line = fault ? "fault" : "hang"
        #expect(drain.withLock { $0.raised }, "the lines before the \(line) line drained at .utility")
        let events = try journalLines(of: try #require(journalFiles(in: folder.url).first)).dropFirst(3).map {
            $0.split(separator: "\t").dropFirst(4).prefix(2).joined(separator: " ")
        }
        #expect(events == ["take start-request", fault ? "device lost" : "hang start"], "\(events)")
    }
}

/// The base and the current scheduling priority of the calling thread.
private func threadPriority() -> (base: Int32, current: Int32) {
    var info = thread_extended_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_extended_info>.size / MemoryLayout<integer_t>.size)
    let thread = mach_thread_self()
    defer { mach_port_deallocate(mach_task_self_, thread) }
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            thread_info(thread, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &count)
        }
    }
    return (info.pth_priority, info.pth_curpri)
}
