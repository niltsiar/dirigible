import DirigibleAudio
import DirigibleCore
import Foundation
import Observation

/// A window that an agent call can reach: its studio, why the app refuses agent edits now
/// (C4), or nil, and the consent sheet of `record` (decision 0048), or nil. With `dialog`, the
/// window shows an alert, a step of Export, or a sheet, so the export sheet of an agent `export`
/// or `render` cannot show: the call is refused (decision 0049).
package struct AgentTarget {
    package typealias Record = @MainActor (RecordRequest, AgentName, AgentConnection) async -> RecordAnswer

    package let studio: Studio
    package let busy: AgentBusy?
    /// True while the window shows an alert, a sheet, or a panel. A live job reads it again after
    /// each await.
    package let dialog: @MainActor () -> Bool
    package let record: Record?

    package init(
        studio: Studio, busy: AgentBusy? = nil, dialog: @escaping @MainActor () -> Bool = { false },
        record: Record? = nil
    ) {
        (self.studio, self.busy, self.dialog, self.record) = (studio, busy, dialog, record)
    }
}

/// Why the app refuses a live agent edit (C4). The CLI keeps the text of `StudioError.busy`.
package enum AgentBusy: Sendable {
    /// The studio is not idle: a take, an import, a level, or the settle of a close.
    case task
    case drag
    case closing
    case quit
    /// A record request waits for the user (decision 0048).
    case asking
    /// The window shows an alert, a sheet, or a panel.
    case dialog
    /// An export of the window runs: a second export waits for its end.
    case export
    /// A take of the package is not finalized.
    case pendingTake

    package func message(package: String) -> String {
        let cause =
            switch self {
            case .task: "a take, an import, a level, or a close runs"
            case .drag: "a drag runs in its window"
            case .closing: "its window closes"
            case .quit: "Dirigible quits"
            case .asking: "a record request waits for the user"
            case .dialog: "its window shows a question"
            case .export: "an export runs in its window"
            case .pendingTake: "a take is not finalized"
            }
        return "\(package) is busy in Dirigible: \(cause). Try again later."
    }
}

/// The app server of decision 0046: the face of `AgentListener` for the app and its views. The
/// app owns one, and starts and stops it with the Settings switch.
@MainActor @Observable
package final class AgentServer {
    package enum State: Equatable, Sendable {
        case off
        case listening
        /// Another copy of the app holds the lock and serves the agents (C9).
        case servedElsewhere
        /// The folder, the lock, or the socket failed, for example a path over 103 bytes (C10).
        case failed
    }

    package private(set) var state = State.off
    /// The number of open bridge connections, for the agent mark (C12).
    package private(set) var connected = 0

    private let socket: URL
    private let log: DiagnosticLog
    private let targets: @MainActor () -> [AgentTarget]
    @ObservationIgnored private(set) var listener: AgentListener?
    /// True from a stop until its listener freed the lock. A start in that time waits for it.
    @ObservationIgnored private(set) var draining = false
    @ObservationIgnored private var startAfterDrain = false
    /// One more for each start, so a count of a stopped listener does not change `connected`.
    @ObservationIgnored private var generation = 0

    /// `targets` gives the windows of the app on each call. `log` gets one line for each call.
    package init(
        socket: URL = agentSocketPath(), log: DiagnosticLog = .disabled,
        targets: @escaping @MainActor () -> [AgentTarget]
    ) {
        (self.socket, self.log, self.targets) = (socket, log, targets)
    }

    package func start() {
        guard listener == nil else { return }
        guard !draining else {
            startAfterDrain = true
            return
        }
        // A second guard after MSG_NOSIGNAL and SO_NOSIGPIPE (C16). It is of the whole process,
        // and a child process of the app gets it too.
        signal(SIGPIPE, SIG_IGN)
        generation += 1
        let generation = generation
        let opening = AgentListener.open(
            socket: socket,
            handle: { [weak self] call, report in
                await self?.answer(call, generation: generation, report: report) ?? .notOpen
            },
            counted: { [weak self] count in
                // The main queue is FIFO, so the last count of the listener is the last one set.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.generation == generation, self.listener != nil else { return }
                        self.connected = count
                    }
                }
            })
        switch opening {
        case .listening(let listener):
            self.listener = listener
            state = .listening
        case .servedElsewhere: state = .servedElsewhere
        case .failed: state = .failed
        }
    }

    /// Closes the listener and the socket file soon, with no wait; each connection closes after
    /// its running call answers. A start during the stop opens when the old lock is free.
    package func stop() {
        startAfterDrain = false
        if let listener {
            draining = true
            listener.stop { [weak self] in
                guard let self else { return }
                draining = false
                if startAfterDrain {
                    startAfterDrain = false
                    start()
                }
            }
        }
        listener = nil
        state = .off
        connected = 0
    }

    /// Writes `agent call` with the tool, the ms, and the error flag, and never an argument
    /// (decision 0059).
    private func answer(_ call: AgentCall, generation: Int, report: @escaping @Sendable (Double) -> Void) async
        -> AgentReply
    {
        let start = ContinuousClock.now
        let reply = await reply(to: call, generation: generation, report: report)
        let failed = if case .result(_, isError: true) = reply { true } else { false }
        log.note(
            .agent, "call",
            [
                "tool": .text(call.tool), "ms": .milliseconds((ContinuousClock.now - start) / .milliseconds(1)),
                "error": .text(failed ? "true" : "false"),
            ])
        return reply
    }

    private func reply(to call: AgentCall, generation: Int, report: @escaping @Sendable (Double) -> Void) async
        -> AgentReply
    {
        guard let target = targets().first(where: { $0.studio.url.path == call.identity.path }) else { return .notOpen }
        if case .record(let request) = call.work { return await liveRecord(request, call, target: target) }
        guard call.work.isLong else { return liveCall(call, target: target) }
        let reply = await liveJob(call, target: target, report: report)
        // A stop of the server cancels the job too, but the agent did not cancel it (decision 0049).
        let stopped = listener == nil || self.generation != generation
        guard stopped, reply == .result(text: cancelledMessage, isError: true) else { return reply }
        return .result(text: serverStopMessage(call.work), isError: true)
    }
}
