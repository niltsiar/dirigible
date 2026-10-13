import DirigibleAudio
import DirigibleCore
import Foundation
import Observation

/// A window that an agent call can reach: its studio, and why the app refuses agent edits now
/// (C4), or nil.
package struct AgentTarget {
    package let studio: Studio
    package let busy: AgentBusy?

    package init(studio: Studio, busy: AgentBusy? = nil) { (self.studio, self.busy) = (studio, busy) }
}

/// Why the app refuses a live agent edit (C4). The CLI keeps the text of `StudioError.busy`.
package enum AgentBusy: Sendable {
    /// The studio is not idle: a take, an import, a level, or the settle of a close.
    case task
    case drag
    case closing
    case quit

    package func message(package: String) -> String {
        let cause =
            switch self {
            case .task: "a take, an import, a level, or a close runs"
            case .drag: "a drag runs in its window"
            case .closing: "its window closes"
            case .quit: "Dirigible quits"
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
    private let targets: @MainActor () -> [AgentTarget]
    @ObservationIgnored private(set) var listener: AgentListener?
    /// One more for each start, so a count of a stopped listener does not change `connected`.
    @ObservationIgnored private var generation = 0

    /// `targets` gives the windows of the app on each call.
    package init(socket: URL = agentSocketPath(), targets: @escaping @MainActor () -> [AgentTarget]) {
        (self.socket, self.targets) = (socket, targets)
    }

    package func start() {
        guard listener == nil else { return }
        // A second guard after MSG_NOSIGNAL and SO_NOSIGPIPE (C16). It is of the whole process,
        // and a child process of the app gets it too.
        signal(SIGPIPE, SIG_IGN)
        generation += 1
        let generation = generation
        let opening = AgentListener.open(
            socket: socket,
            handle: { [weak self] call in await self?.answer(call) ?? .notOpen },
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

    /// Closes the listener and the socket file at once; each connection closes after its running
    /// call answers.
    package func stop() {
        listener?.stop()
        listener = nil
        state = .off
        connected = 0
    }

    private func answer(_ call: AgentCall) -> AgentReply {
        guard let target = targets().first(where: { $0.studio.url.path == call.identity.path }) else { return .notOpen }
        return liveCall(call, target: target)
    }
}
